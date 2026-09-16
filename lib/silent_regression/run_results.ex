defmodule SilentRegression.RunResults do
  @moduledoc """
  Workspace-scoped run findings and the small durable alert lifecycle.

  Alert synchronization is safe to retry. Finding identity is enforced by the database so concurrent
  workers cannot create duplicate action items.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit

  alias SilentRegression.Captures.{CaptureRuleResult, CaptureRun}

  alias SilentRegression.Repo
  alias SilentRegression.RunResults.{Alert, Policy}
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @terminal_run_statuses [:succeeded, :partial_failed, :failed, :cancelled, :needs_review]

  @doc false
  def sync_run(run_id) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      Repo.transaction(fn ->
        case locked_run(run_id) do
          nil ->
            Repo.rollback(:not_found)

          %CaptureRun{status: status} when status not in @terminal_run_statuses ->
            %{status: :pending, alert_count: 0}

          %CaptureRun{kind: :baseline} ->
            %{status: :ignored_baseline, alert_count: 0}

          %CaptureRun{} = run ->
            run = preload_for_policy(run)
            findings = Policy.findings(run)
            Enum.each(findings, &insert_finding!(run, &1))
            %{status: :synchronized, alert_count: length(findings)}
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def get_alert(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        alert_id
      ) do
    with {:ok, alert_id} <- Ecto.UUID.cast(alert_id),
         %Alert{} = alert <- load_alert(workspace_id, alert_id) do
      {:ok, alert}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_alert(%Scope{}, _alert_id), do: {:error, :workspace_required}

  def acknowledge_alert(scope, alert_id, options \\ [])

  def acknowledge_alert(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        alert_id,
        options
      ) do
    with {:ok, alert_id} <- Ecto.UUID.cast(alert_id) do
      at = operation_time(options)

      Repo.transaction(fn ->
        case locked_alert(workspace_id, alert_id) do
          %Alert{status: :open} = alert ->
            alert = alert |> Alert.acknowledge_changeset(user, at) |> Repo.update!()
            record_lifecycle!(alert, user, "alert.acknowledged", at)
            alert

          %Alert{} = alert ->
            alert

          nil ->
            Repo.rollback(:not_found)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def acknowledge_alert(%Scope{}, _alert_id, _options), do: {:error, :workspace_required}

  def resolve_alert(scope, alert_id, options \\ [])

  def resolve_alert(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        alert_id,
        options
      ) do
    with {:ok, alert_id} <- Ecto.UUID.cast(alert_id) do
      at = operation_time(options)

      Repo.transaction(fn ->
        case locked_alert(workspace_id, alert_id) do
          %Alert{status: :acknowledged} = alert ->
            alert = alert |> Alert.resolve_changeset(user, at) |> Repo.update!()
            record_lifecycle!(alert, user, "alert.resolved", at)
            alert

          %Alert{status: :resolved} = alert ->
            alert

          %Alert{status: :open} ->
            Repo.rollback(:acknowledgement_required)

          nil ->
            Repo.rollback(:not_found)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def resolve_alert(%Scope{}, _alert_id, _options), do: {:error, :owner_required}

  defp insert_finding!(run, finding) do
    associations = %{
      workspace_id: run.workspace_id,
      monitor_id: run.monitor_id,
      capture_run_id: run.id,
      capture_evaluation_id: finding.capture_evaluation_id
    }

    attrs = Map.put(finding, :opened_at, run.completed_at || DateTime.utc_now())

    %Alert{}
    |> Alert.create_changeset(associations, attrs)
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:workspace_id, :identity_key]
    )
  end

  defp preload_for_policy(run) do
    Repo.preload(
      run,
      [
        baseline_snapshot: [members: :capture_observation],
        observations: [
          :case_version,
          evaluations: [
            rule_results: from(result in CaptureRuleResult, order_by: result.position)
          ]
        ]
      ],
      force: true
    )
  end

  defp record_lifecycle!(alert, user, action, at) do
    Audit.record_event!(%{
      action: action,
      target_type: "result_alert",
      target_id: alert.id,
      workspace_id: alert.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "capture_run_id" => alert.capture_run_id,
        "category" => Atom.to_string(alert.category),
        "severity" => Atom.to_string(alert.severity),
        "code" => alert.code,
        "at" => DateTime.to_iso8601(at)
      }
    })
  end

  defp operation_time(options) do
    case Keyword.get(options, :at) do
      %DateTime{} = at -> DateTime.truncate(at, :microsecond)
      nil -> DateTime.utc_now()
    end
  end

  defp locked_run(run_id) do
    CaptureRun
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_alert(workspace_id, alert_id) do
    Alert
    |> where([alert], alert.workspace_id == ^workspace_id and alert.id == ^alert_id)
    |> Repo.one()
  end

  defp locked_alert(workspace_id, alert_id) do
    Alert
    |> where([alert], alert.workspace_id == ^workspace_id and alert.id == ^alert_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
