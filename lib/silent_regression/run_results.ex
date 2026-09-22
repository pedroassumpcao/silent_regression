defmodule SilentRegression.RunResults do
  @moduledoc """
  Workspace-scoped run findings and the small durable alert lifecycle.

  Alert synchronization is safe to retry. Finding identity is enforced by the database so concurrent
  workers cannot create duplicate action items.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.Captures.{CaptureRuleResult, CaptureRun, ProviderAttempt}
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.Notifications
  alias SilentRegression.Repo
  alias SilentRegression.Reviews
  alias SilentRegression.RunResults.{Alert, Incident, Incidents, Policy}
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @terminal_run_statuses [:succeeded, :partial_failed, :failed, :cancelled, :needs_review]
  @history_limit 25
  @alert_limit 100

  def get_monitor_overview(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{} = membership
        },
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Monitor{} = monitor <- load_monitor(workspace_id, monitor_id) do
      runs = history_runs(workspace_id, monitor.id)
      alerts = monitor_alerts(workspace_id, monitor.id)
      alerts_by_run = Enum.group_by(alerts, & &1.capture_run_id)

      {:ok,
       %{
         monitor: monitor,
         runs: Enum.map(runs, &%{run: &1, alerts: Map.get(alerts_by_run, &1.id, [])}),
         alerts: alerts,
         current_baseline: current_baseline(workspace_id, monitor.id),
         can_resolve?: membership.role == :owner
       }}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_monitor_overview(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def get_run_detail(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{} = membership
        } = scope,
        monitor_id,
        run_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id),
         %Monitor{} = monitor <- load_monitor(workspace_id, monitor_id),
         %CaptureRun{} = run <- load_detail_run(workspace_id, monitor.id, run_id),
         {:ok, review_state} <- Reviews.list_run_reviews(scope, run.id) do
      {:ok,
       %{
         monitor: monitor,
         run: run,
         alerts: run_alerts(workspace_id, run.id),
         reviews: review_state.decisions,
         review_summary: review_state.summary,
         can_resolve?: membership.role == :owner
       }}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_run_detail(%Scope{}, _monitor_id, _run_id), do: {:error, :workspace_required}

  def unresolved_alert_count(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         true <- monitor_exists?(workspace_id, monitor_id) do
      count =
        Incident
        |> where(
          [incident],
          incident.workspace_id == ^workspace_id and incident.monitor_id == ^monitor_id and
            incident.status in [:open, :acknowledged]
        )
        |> Repo.aggregate(:count)

      {:ok, count}
    else
      _reason -> {:error, :not_found}
    end
  end

  def unresolved_alert_count(%Scope{}, _monitor_id), do: {:error, :workspace_required}

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

            recovered_count =
              if Policy.recovery_eligible?(run, findings),
                do: Incidents.recover_for_clean_run!(run),
                else: 0

            %{
              status: :synchronized,
              alert_count: length(findings),
              recovered_incident_count: recovered_count
            }
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

    alert =
      Repo.get_by!(Alert, workspace_id: run.workspace_id, identity_key: finding.identity_key)

    attachment = Incidents.attach_finding!(run, alert, finding)

    if Incidents.notification_event?(attachment.event) do
      Notifications.prepare_incident!(
        attachment.incident,
        attachment.occurrence,
        alert
      )
    end

    attachment
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

  defp locked_run(run_id) do
    CaptureRun
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_monitor(workspace_id, monitor_id) do
    Monitor
    |> where(
      [monitor],
      monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id
    )
    |> preload(:active_version)
    |> Repo.one()
  end

  defp monitor_exists?(workspace_id, monitor_id) do
    Monitor
    |> where(
      [monitor],
      monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id
    )
    |> Repo.exists?()
  end

  defp history_runs(workspace_id, monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.workspace_id == ^workspace_id and run.monitor_id == ^monitor_id and
        run.kind in [:baseline, :manual, :scheduled]
    )
    |> order_by([run], desc: run.inserted_at, desc: run.id)
    |> limit(@history_limit)
    |> preload([:baseline_snapshot, observations: [:provider_attempts, :evaluations]])
    |> Repo.all()
  end

  defp load_detail_run(workspace_id, monitor_id, run_id) do
    run =
      CaptureRun
      |> where(
        [run],
        run.workspace_id == ^workspace_id and run.monitor_id == ^monitor_id and run.id == ^run_id
      )
      |> Repo.one()

    if run do
      attempt_query = from(attempt in ProviderAttempt, order_by: attempt.attempt_number)
      rule_query = from(result in CaptureRuleResult, order_by: result.position)

      Repo.preload(run, [
        :monitor_version,
        baseline_snapshot: [members: :capture_observation],
        observations: [
          :case_version,
          provider_attempts: attempt_query,
          evaluations: [rule_results: rule_query]
        ]
      ])
    end
  end

  defp current_baseline(workspace_id, monitor_id) do
    BaselineSnapshot
    |> where(
      [baseline],
      baseline.workspace_id == ^workspace_id and baseline.monitor_id == ^monitor_id and
        baseline.status == :approved
    )
    |> Repo.one()
  end

  defp monitor_alerts(workspace_id, monitor_id) do
    Alert
    |> where(
      [alert],
      alert.workspace_id == ^workspace_id and alert.monitor_id == ^monitor_id
    )
    |> order_by([alert], desc: alert.opened_at, desc: alert.id)
    |> limit(@alert_limit)
    |> preload([
      :monitor,
      :capture_run,
      :acknowledged_by_user,
      :resolved_by_user,
      :resolution_review_decision,
      incident_occurrence: [incident: [:acknowledged_by_user, :resolved_by_user]]
    ])
    |> Repo.all()
  end

  defp run_alerts(workspace_id, run_id) do
    Alert
    |> where(
      [alert],
      alert.workspace_id == ^workspace_id and alert.capture_run_id == ^run_id
    )
    |> order_by([alert], asc: alert.inserted_at, asc: alert.id)
    |> preload([
      :monitor,
      :capture_run,
      :acknowledged_by_user,
      :resolved_by_user,
      :resolution_review_decision,
      incident_occurrence: [incident: [:acknowledged_by_user, :resolved_by_user]]
    ])
    |> Repo.all()
  end

  defp load_alert(workspace_id, alert_id) do
    Alert
    |> where([alert], alert.workspace_id == ^workspace_id and alert.id == ^alert_id)
    |> preload(:resolution_review_decision)
    |> Repo.one()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
