defmodule SilentRegression.ProductAnalytics do
  @moduledoc """
  Records a deliberately small, content-free product-learning event allowlist.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit.AuditEvent
  alias SilentRegression.ProductAnalytics.ProductEvent
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @property_allowlist %{
    "monitor_setup.started" => ["step"],
    "monitor_setup.step_completed" => ["step", "completed_count", "total_count"],
    "monitor_setup.left" => ["step", "completed_count", "total_count"],
    "monitor_setup.completed" => ["completed_count", "total_count"],
    "monitor_successor.started" => ["motivated_by_review"],
    "monitor_successor.activated" => ["replacement_reference_required"],
    "baseline.approved" => ["approval_mode"],
    "schedule.activated" => ["cadence", "activation_kind"],
    "review.recorded" => ["subject_kind", "classification", "action", "superseded"],
    "review.action_started" => ["action"],
    "founder.assistance_recorded" => ["stage", "reason"]
  }

  @steps ~w(purpose connection prompt cases review)
  @activation_stages ~w(credential workflow cases contract baseline schedule review)
  @assistance_reasons ~w(onboarding correction provider security other)
  @review_subjects ~w(alert observation)
  @review_classifications ~w(
    correct_pass confirmed_regression acceptable_variation contract_needs_revision
    test_case_or_baseline_problem passed_but_should_have_failed unsure operational_anomaly
  )
  @review_actions ~w(
    none prompt_change case_change contract_revision provider_change operational_follow_up
  )

  def record!(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{},
          user: %User{} = user
        },
        name,
        monitor_id,
        properties
      )
      when is_binary(name) and is_map(properties) do
    :ok = validate_properties(name, properties)

    %ProductEvent{}
    |> ProductEvent.record_changeset(%{
      name: name,
      target_type: "monitor",
      target_id: monitor_id,
      properties: properties,
      occurred_at: DateTime.utc_now(:second),
      workspace_id: workspace.id,
      actor_user_id: user.id
    })
    |> Repo.insert!()
  end

  def list_events(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{}
      }) do
    ProductEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> order_by([event], asc: event.occurred_at, asc: event.inserted_at)
    |> Repo.all()
  end

  def list_events(%Scope{}), do: {:error, :workspace_required}

  def record_founder_assistance!(%Scope{} = scope, monitor_id, stage, reason) do
    record!(scope, "founder.assistance_recorded", monitor_id, %{
      "reason" => to_string(reason),
      "stage" => to_string(stage)
    })
  end

  def activation_funnel(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{}
      }) do
    events =
      ProductEvent
      |> where([event], event.workspace_id == ^workspace_id)
      |> order_by([event], asc: event.occurred_at, asc: event.inserted_at)
      |> Repo.all()

    invitation_accepted_at =
      AuditEvent
      |> where([event], event.workspace_id == ^workspace_id)
      |> where([event], event.action == "invitation.accepted")
      |> order_by([event], asc: event.occurred_at, asc: event.inserted_at)
      |> select([event], event.occurred_at)
      |> limit(1)
      |> Repo.one()

    first_activation_at =
      events
      |> Enum.find(&(&1.name == "schedule.activated"))
      |> then(&(&1 && &1.occurred_at))

    %{
      invitation_accepted_at: invitation_accepted_at,
      first_monitor_activated_at: first_activation_at,
      seconds_to_first_monitor: elapsed_seconds(invitation_accepted_at, first_activation_at),
      event_counts: Enum.frequencies_by(events, & &1.name),
      abandonment_by_step: property_frequency(events, "monitor_setup.left", "step"),
      assistance_by_stage: property_frequency(events, "founder.assistance_recorded", "stage")
    }
  end

  def activation_funnel(%Scope{}), do: {:error, :workspace_required}

  defp validate_properties(name, properties) do
    with {:ok, allowed_keys} <- Map.fetch(@property_allowlist, name),
         [] <- Map.keys(properties) -- allowed_keys,
         :ok <- validate_property_values(properties) do
      :ok
    else
      _reason -> raise ArgumentError, "invalid product event or properties"
    end
  end

  defp validate_property_values(properties) do
    valid? =
      Enum.all?(properties, fn
        {"step", value} ->
          value in @steps

        {key, value} when key in ["completed_count", "total_count"] ->
          is_integer(value) and value >= 0 and value <= 5

        {"approval_mode", value} ->
          value in ~w(normal exceptional)

        {"cadence", value} ->
          value in ~w(manual daily weekly)

        {"activation_kind", value} ->
          value in ~w(configured resumed)

        {"subject_kind", value} ->
          value in @review_subjects

        {"classification", value} ->
          value in @review_classifications

        {"action", value} ->
          value in @review_actions

        {"superseded", value} ->
          is_boolean(value)

        {key, value}
        when key in ["motivated_by_review", "replacement_reference_required"] ->
          is_boolean(value)

        {"stage", value} ->
          value in @activation_stages

        {"reason", value} ->
          value in @assistance_reasons

        _property ->
          false
      end)

    if valid?, do: :ok, else: :error
  end

  defp elapsed_seconds(%DateTime{} = started_at, %DateTime{} = completed_at) do
    max(DateTime.diff(completed_at, started_at, :second), 0)
  end

  defp elapsed_seconds(_started_at, _completed_at), do: nil

  defp property_frequency(events, name, property) do
    events
    |> Enum.filter(&(&1.name == name))
    |> Enum.map(&Map.get(&1.properties, property))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end
end
