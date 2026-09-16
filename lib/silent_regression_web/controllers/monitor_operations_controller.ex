defmodule SilentRegressionWeb.MonitorOperationsController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.MonitorOperations

  def show(conn, %{"monitor_id" => monitor_id}) do
    case MonitorOperations.get_state(conn.assigns.current_scope, monitor_id) do
      {:ok, state} ->
        render_operations(conn, state)

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        operation_failed(conn, monitor_id, "Monitor operations are unavailable.")
    end
  end

  def configure(conn, %{"monitor_id" => monitor_id} = params) do
    case MonitorOperations.configure(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "schedule", %{})
         ) do
      {:ok, monitor} ->
        action =
          if monitor.state == :active, do: "Monitoring schedule saved.", else: "Schedule saved."

        conn
        |> put_flash(:info, action)
        |> redirect(to: operations_path(conn, monitor_id))

      {:error, reason} ->
        handle_operation_error(conn, monitor_id, reason)
    end
  end

  def run_now(conn, %{"monitor_id" => monitor_id}) do
    case MonitorOperations.run_now(conn.assigns.current_scope, monitor_id) do
      {:ok, _run} ->
        conn
        |> put_flash(:info, "Run queued with the displayed provider-call limit.")
        |> redirect(to: operations_path(conn, monitor_id))

      {:error, reason} ->
        handle_operation_error(conn, monitor_id, reason)
    end
  end

  def pause(conn, %{"monitor_id" => monitor_id}) do
    case MonitorOperations.pause(conn.assigns.current_scope, monitor_id) do
      {:ok, _monitor} ->
        conn
        |> put_flash(:info, "Monitor paused. Unfinished queued work was cancelled.")
        |> redirect(to: operations_path(conn, monitor_id))

      {:error, reason} ->
        handle_operation_error(conn, monitor_id, reason)
    end
  end

  def resume(conn, %{"monitor_id" => monitor_id}) do
    case MonitorOperations.resume(conn.assigns.current_scope, monitor_id) do
      {:ok, _monitor} ->
        conn
        |> put_flash(:info, "Monitor resumed from a fresh schedule anchor.")
        |> redirect(to: operations_path(conn, monitor_id))

      {:error, reason} ->
        handle_operation_error(conn, monitor_id, reason)
    end
  end

  defp render_operations(conn, state) do
    monitor = state.monitor
    version = monitor.active_version

    conn
    |> assign(:page_title, "Monitor operations · #{monitor.name}")
    |> render_inertia("Monitors/Operations", %{
      approved_baseline: state.approved_baseline?,
      can_manage: state.can_manage?,
      last_run: run_prop(state.last_run),
      monitor: %{
        id: monitor.id,
        name: monitor.name,
        description: monitor.description,
        state: monitor.state,
        cadence: monitor.cadence,
        next_run_at: monitor.next_run_at,
        last_scheduled_at: monitor.last_scheduled_at,
        schedule_updated_at: monitor.schedule_updated_at,
        schedule_updated_by:
          monitor.schedule_updated_by_user && monitor.schedule_updated_by_user.email,
        pause_reason: monitor.pause_reason,
        provider: version && version.provider,
        requested_model: version && version.requested_model,
        version: version && version.version
      },
      release_stage: "Private alpha",
      unresolved_alerts: state.unresolved_alerts,
      spend: %{
        case_count: div(state.maximum_call_count, 2),
        maximum_call_count: state.maximum_call_count,
        workspace_call_limit: state.workspace_call_limit,
        workspace_committed_calls_today: state.workspace_committed_calls_today,
        workspace_remaining_calls_today:
          max(state.workspace_call_limit - state.workspace_committed_calls_today, 0)
      }
    })
  end

  defp run_prop(nil), do: nil

  defp run_prop(run) do
    %{
      id: run.id,
      kind: run.kind,
      status: run.status,
      planned_call_count: run.planned_call_count,
      maximum_call_count: run.maximum_call_count,
      started_at: run.started_at,
      completed_at: run.completed_at,
      inserted_at: run.inserted_at
    }
  end

  defp handle_operation_error(conn, monitor_id, :owner_required) do
    operation_failed(conn, monitor_id, "Only a workspace owner can change monitor operations.")
  end

  defp handle_operation_error(conn, _monitor_id, :not_found) do
    send_resp(conn, :not_found, "Not found")
  end

  defp handle_operation_error(conn, monitor_id, :baseline_required) do
    operation_failed(
      conn,
      monitor_id,
      "Approve a compatible baseline before activating monitoring."
    )
  end

  defp handle_operation_error(conn, monitor_id, :incompatible_baseline) do
    operation_failed(
      conn,
      monitor_id,
      "The approved baseline no longer matches the active behavior. Capture a compatible replacement."
    )
  end

  defp handle_operation_error(conn, monitor_id, :credential_unavailable) do
    operation_failed(
      conn,
      monitor_id,
      "Validate the exact provider credential and model before continuing."
    )
  end

  defp handle_operation_error(conn, monitor_id, :workspace_call_limit) do
    operation_failed(
      conn,
      monitor_id,
      "The workspace provider-call limit is exhausted for today."
    )
  end

  defp handle_operation_error(conn, monitor_id, :run_in_progress) do
    operation_failed(conn, monitor_id, "This monitor already has an unfinished run.")
  end

  defp handle_operation_error(conn, monitor_id, :repeated_authentication_failures) do
    operation_failed(
      conn,
      monitor_id,
      "Repeated provider authentication failures must be resolved first."
    )
  end

  defp handle_operation_error(conn, monitor_id, _reason) do
    operation_failed(conn, monitor_id, "The monitor operation could not be completed.")
  end

  defp operation_failed(conn, monitor_id, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: operations_path(conn, monitor_id))
  end

  defp operations_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/operations"
  end
end
