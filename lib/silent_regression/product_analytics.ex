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
    "demo.started" => ["scenario_version"],
    "demo.step_completed" => ["demo_step", "step_number", "scenario_version"],
    "demo.completed" => ["total_count", "scenario_version"],
    "baseline.approved" => ["approval_mode"],
    "schedule.activated" => ["cadence", "activation_kind"],
    "review.recorded" => ["subject_kind", "classification", "action", "superseded"],
    "review.action_started" => ["action"],
    "founder.assistance_recorded" => ["stage", "reason"]
  }

  @steps ~w(purpose connection prompt cases review)
  @activation_stages ~w(demo credential workflow cases contract baseline schedule review)
  @demo_steps ~w(request expectation reference incident)
  @demo_scenario_version "credential-free-demo-v1"
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

    insert_event!(workspace, user, name, "monitor", monitor_id, properties)
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

  def record_demo_assistance!(
        %Scope{workspace: %Workspace{} = workspace} = scope,
        reason
      ) do
    record_workspace_event!(
      scope,
      "founder.assistance_recorded",
      %{
        "reason" => to_string(reason),
        "stage" => "demo"
      },
      workspace.id
    )
  end

  def start_demo(%Scope{} = scope) do
    Repo.transaction(fn ->
      lock_workspace!(scope)

      case demo_events(scope) |> Enum.find(&(&1.name == "demo.started")) do
        nil ->
          record_workspace_event!(scope, "demo.started", %{
            "scenario_version" => @demo_scenario_version
          })

        event ->
          event
      end

      demo_progress(scope)
    end)
  end

  def complete_demo_step(%Scope{} = scope, step) when is_binary(step) do
    Repo.transaction(fn ->
      lock_workspace!(scope)
      events = demo_events(scope)

      if Enum.any?(events, &(&1.name == "demo.started")) do
        completed = completed_demo_steps(events)
        expected = Enum.at(@demo_steps, length(completed))

        cond do
          step in completed ->
            demo_progress(scope)

          step != expected ->
            Repo.rollback(:out_of_order)

          true ->
            record_workspace_event!(scope, "demo.step_completed", %{
              "demo_step" => step,
              "step_number" => length(completed) + 1,
              "scenario_version" => @demo_scenario_version
            })

            if step == List.last(@demo_steps) and
                 not Enum.any?(events, &(&1.name == "demo.completed")) do
              record_workspace_event!(scope, "demo.completed", %{
                "total_count" => length(@demo_steps),
                "scenario_version" => @demo_scenario_version
              })
            end

            demo_progress(scope)
        end
      else
        Repo.rollback(:not_started)
      end
    end)
  end

  def complete_demo_step(%Scope{}, _step), do: {:error, :invalid_step}

  def demo_progress(%Scope{} = scope) do
    events = demo_events(scope)
    started = Enum.find(events, &(&1.name == "demo.started"))
    completed_event = Enum.find(events, &(&1.name == "demo.completed"))
    completed_steps = completed_demo_steps(events)
    expectation_event = demo_step_event(events, "expectation")

    %{
      status: demo_status(started, completed_event),
      scenario_version: @demo_scenario_version,
      completed_steps: completed_steps,
      completed_count: length(completed_steps),
      total_count: length(@demo_steps),
      current_step: Enum.at(@demo_steps, length(completed_steps)),
      started_at: event_time(started),
      expectation_proven_at: event_time(expectation_event),
      completed_at: event_time(completed_event),
      seconds_to_expectation: elapsed_seconds(event_time(started), event_time(expectation_event)),
      seconds_to_completion: elapsed_seconds(event_time(started), event_time(completed_event))
    }
  end

  def demo_funnel(%Scope{} = scope) do
    events = list_events(scope)
    demo_events = Enum.filter(events, &String.starts_with?(&1.name, "demo."))
    journeys = Enum.group_by(demo_events, & &1.actor_user_id)

    %{
      started_count: count_actors(demo_events, "demo.started"),
      completed_count: count_actors(demo_events, "demo.completed"),
      step_counts:
        demo_events
        |> Enum.filter(&(&1.name == "demo.step_completed"))
        |> Enum.frequencies_by(& &1.properties["demo_step"]),
      assistance_count:
        Enum.count(events, fn event ->
          event.name == "founder.assistance_recorded" and event.properties["stage"] == "demo"
        end),
      median_seconds_to_expectation:
        journeys
        |> journey_durations("demo.started", "expectation")
        |> median(),
      median_seconds_to_completion:
        journeys
        |> journey_durations("demo.started", "demo.completed")
        |> median()
    }
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

        {"demo_step", value} ->
          value in @demo_steps

        {"step_number", value} ->
          is_integer(value) and value >= 1 and value <= length(@demo_steps)

        {"scenario_version", value} ->
          value == @demo_scenario_version

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

  defp record_workspace_event!(
         %Scope{workspace: %Workspace{} = workspace, user: %User{} = user},
         name,
         properties,
         target_id \\ nil
       ) do
    :ok = validate_properties(name, properties)
    insert_event!(workspace, user, name, "workspace", target_id || workspace.id, properties)
  end

  defp insert_event!(workspace, user, name, target_type, target_id, properties) do
    %ProductEvent{}
    |> ProductEvent.record_changeset(%{
      name: name,
      target_type: target_type,
      target_id: target_id,
      properties: properties,
      occurred_at: DateTime.utc_now(:second),
      workspace_id: workspace.id,
      actor_user_id: user.id
    })
    |> Repo.insert!()
  end

  defp lock_workspace!(%Scope{workspace: %Workspace{id: workspace_id}}) do
    Workspace
    |> where([workspace], workspace.id == ^workspace_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp demo_events(%Scope{
         workspace: %Workspace{id: workspace_id},
         membership: %Membership{},
         user: %User{id: actor_user_id}
       }) do
    ProductEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> where([event], event.actor_user_id == ^actor_user_id)
    |> where([event], event.target_type == "workspace" and event.target_id == ^workspace_id)
    |> where([event], event.name in ["demo.started", "demo.step_completed", "demo.completed"])
    |> order_by([event], asc: event.occurred_at, asc: event.inserted_at)
    |> Repo.all()
  end

  defp completed_demo_steps(events) do
    completed =
      events
      |> Enum.filter(&(&1.name == "demo.step_completed"))
      |> MapSet.new(& &1.properties["demo_step"])

    Enum.filter(@demo_steps, &MapSet.member?(completed, &1))
  end

  defp demo_step_event(events, step) do
    Enum.find(events, fn event ->
      event.name == "demo.step_completed" and event.properties["demo_step"] == step
    end)
  end

  defp demo_status(nil, _completed), do: :not_started
  defp demo_status(_started, nil), do: :in_progress
  defp demo_status(_started, _completed), do: :completed

  defp event_time(nil), do: nil
  defp event_time(event), do: event.occurred_at

  defp count_actors(events, name) do
    events
    |> Enum.filter(&(&1.name == name))
    |> Enum.map(& &1.actor_user_id)
    |> Enum.uniq()
    |> length()
  end

  defp journey_durations(journeys, start_name, finish) do
    journeys
    |> Map.values()
    |> Enum.map(fn events ->
      started = Enum.find(events, &(&1.name == start_name))

      finished =
        if finish == "expectation",
          do: demo_step_event(events, "expectation"),
          else: Enum.find(events, &(&1.name == finish))

      elapsed_seconds(event_time(started), event_time(finished))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1 do
      Enum.at(sorted, middle)
    else
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    end
  end
end
