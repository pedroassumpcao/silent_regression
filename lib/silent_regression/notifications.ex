defmodule SilentRegression.Notifications do
  @moduledoc """
  Workspace-scoped alert preferences and the durable email delivery outbox.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Mailer
  alias SilentRegression.Notifications.{AlertEmail, Delivery, Preference}
  alias SilentRegression.Notifications.Workers.AlertEmailWorker
  alias SilentRegression.Repo
  alias SilentRegression.RunResults.Alert
  alias SilentRegression.Workspaces.{Membership, Workspace}

  def get_preference(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{},
        user: %User{id: user_id}
      }) do
    Repo.get_by(Preference, workspace_id: workspace_id, user_id: user_id) ||
      %Preference{
        workspace_id: workspace_id,
        user_id: user_id,
        actionable_alert_email_enabled: true
      }
  end

  def get_preference(%Scope{}), do: {:error, :workspace_required}

  def update_preference(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{id: user_id}
        },
        attrs
      )
      when is_map(attrs) do
    existing = Repo.get_by(Preference, workspace_id: workspace_id, user_id: user_id)

    (existing || %Preference{})
    |> Preference.changeset(%{workspace_id: workspace_id, user_id: user_id}, attrs)
    |> Repo.insert_or_update()
  end

  def update_preference(%Scope{}, _attrs), do: {:error, :workspace_required}

  @doc false
  def prepare_alert!(%Alert{} = alert) do
    now = DateTime.utc_now()

    entries =
      alert.workspace_id
      |> eligible_recipient_ids()
      |> Enum.map(fn user_id ->
        %{
          id: Ecto.UUID.generate(),
          kind: :actionable_alert,
          channel: :email,
          status: :pending,
          attempts: 0,
          workspace_id: alert.workspace_id,
          result_alert_id: alert.id,
          recipient_user_id: user_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} =
      Repo.insert_all(Delivery, entries,
        on_conflict: :nothing,
        conflict_target: [:result_alert_id, :recipient_user_id, :channel],
        returning: [:id]
      )

    Enum.each(inserted || [], fn %{id: delivery_id} ->
      %{"delivery_id" => delivery_id}
      |> AlertEmailWorker.new()
      |> Oban.insert!()
    end)

    refresh_alert_notification_state!(alert.id)
    :ok
  end

  @doc false
  def deliver_alert_email(delivery_id) do
    with {:ok, delivery_id} <- Ecto.UUID.cast(delivery_id),
         {:ok, delivery} <- claim_delivery(delivery_id) do
      case delivery do
        %Delivery{status: :sent} ->
          :ok

        %Delivery{status: :skipped} ->
          :ok

        %Delivery{} ->
          email =
            AlertEmail.build(
              delivery.result_alert,
              delivery.result_alert.monitor,
              delivery.recipient_user,
              delivery.result_alert.workspace.slug
            )

          case Mailer.deliver(email) do
            {:ok, _metadata} -> complete_delivery(delivery.id, :sent)
            {:error, _reason} -> complete_delivery(delivery.id, :failed)
          end
      end
    else
      :error -> {:discard, :invalid_delivery_id}
      {:error, :not_found} -> {:discard, :delivery_not_found}
    end
  rescue
    _error -> {:error, :delivery_exception}
  end

  def list_deliveries(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{}
      }) do
    Delivery
    |> where([delivery], delivery.workspace_id == ^workspace_id)
    |> order_by([delivery], asc: delivery.inserted_at, asc: delivery.id)
    |> Repo.all()
  end

  def list_deliveries(%Scope{}), do: {:error, :workspace_required}

  defp eligible_recipient_ids(workspace_id) do
    Membership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> join(:left, [membership, _user], preference in Preference,
      on:
        preference.workspace_id == membership.workspace_id and
          preference.user_id == membership.user_id
    )
    |> where(
      [membership, _user, preference],
      membership.workspace_id == ^workspace_id and
        (is_nil(preference.id) or preference.actionable_alert_email_enabled)
    )
    |> select([_membership, user, _preference], user.id)
    |> Repo.all()
  end

  defp claim_delivery(delivery_id) do
    Repo.transaction(fn ->
      case locked_delivery(delivery_id) do
        nil ->
          Repo.rollback(:not_found)

        %Delivery{status: status} = delivery when status in [:sent, :skipped] ->
          delivery

        %Delivery{} = delivery ->
          case delivery_eligibility(delivery) do
            :eligible ->
              delivery
              |> Delivery.attempt_changeset(DateTime.utc_now())
              |> Repo.update!()
              |> Repo.preload([:recipient_user, result_alert: [:monitor, :workspace]])

            {:skip, reason} ->
              delivery
              |> Delivery.skipped_changeset(reason)
              |> Repo.update!()
              |> tap(&refresh_alert_notification_state!(&1.result_alert_id))
          end
      end
    end)
    |> unwrap_transaction()
  end

  defp delivery_eligibility(delivery) do
    member? =
      Repo.exists?(
        from membership in Membership,
          where:
            membership.workspace_id == ^delivery.workspace_id and
              membership.user_id == ^delivery.recipient_user_id
      )

    preference =
      Repo.get_by(Preference,
        workspace_id: delivery.workspace_id,
        user_id: delivery.recipient_user_id
      )

    cond do
      not member? -> {:skip, :recipient_unavailable}
      preference && not preference.actionable_alert_email_enabled -> {:skip, :preference_disabled}
      true -> :eligible
    end
  end

  defp complete_delivery(delivery_id, outcome) do
    result =
      Repo.transaction(fn ->
        case locked_delivery(delivery_id) do
          nil ->
            Repo.rollback(:not_found)

          %Delivery{status: :sent} = delivery ->
            delivery

          %Delivery{} = delivery ->
            changeset =
              case outcome do
                :sent -> Delivery.sent_changeset(delivery, DateTime.utc_now())
                :failed -> Delivery.failed_changeset(delivery)
              end

            changeset
            |> Repo.update!()
            |> tap(&refresh_alert_notification_state!(&1.result_alert_id))
        end
      end)

    case {outcome, result} do
      {:sent, {:ok, _delivery}} -> :ok
      {:failed, {:ok, _delivery}} -> {:error, :delivery_failed}
      {_outcome, {:error, :not_found}} -> {:discard, :delivery_not_found}
    end
  end

  defp locked_delivery(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp refresh_alert_notification_state!(alert_id) do
    statuses =
      Delivery
      |> where([delivery], delivery.result_alert_id == ^alert_id)
      |> group_by([delivery], delivery.status)
      |> select([delivery], {delivery.status, count(delivery.id)})
      |> Repo.all()
      |> Map.new()

    state =
      cond do
        Map.get(statuses, :pending, 0) > 0 -> :pending
        Map.get(statuses, :failed, 0) > 0 -> :failed
        Map.get(statuses, :sent, 0) > 0 -> :sent
        true -> :not_configured
      end

    Alert
    |> where([alert], alert.id == ^alert_id)
    |> Repo.update_all(set: [notification_state: state, updated_at: DateTime.utc_now()])

    state
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
