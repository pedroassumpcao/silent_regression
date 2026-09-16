defmodule SilentRegressionWeb.RunResultController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.Presenter

  def index(conn, %{"monitor_id" => monitor_id}) do
    case RunResults.get_monitor_overview(conn.assigns.current_scope, monitor_id) do
      {:ok, state} ->
        monitor = state.monitor

        conn
        |> assign(:page_title, "Results · #{monitor.name}")
        |> render_inertia("Monitors/Results", %{
          alerts: Enum.map(state.alerts, &Presenter.alert/1),
          can_resolve: state.can_resolve?,
          current_baseline: baseline_prop(state.current_baseline),
          monitor: monitor_prop(monitor),
          release_stage: "Private alpha",
          runs:
            Enum.map(state.runs, fn entry ->
              Presenter.run_summary(entry.run, entry.alerts)
            end)
        })

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def show(conn, %{"monitor_id" => monitor_id, "run_id" => run_id}) do
    case RunResults.get_run_detail(conn.assigns.current_scope, monitor_id, run_id) do
      {:ok, state} ->
        conn
        |> assign(:page_title, "Run evidence · #{state.monitor.name}")
        |> render_inertia("Monitors/Run", %{
          can_resolve: state.can_resolve?,
          monitor: monitor_prop(state.monitor),
          release_stage: "Private alpha",
          result: Presenter.run_detail(state.run, state.alerts)
        })

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def diagnostic(conn, %{"monitor_id" => monitor_id, "run_id" => run_id}) do
    case RunResults.get_run_detail(conn.assigns.current_scope, monitor_id, run_id) do
      {:ok, state} ->
        payload = state.run |> Presenter.diagnostic(state.alerts) |> Jason.encode!(pretty: true)

        send_download(conn, {:binary, payload},
          content_type: "application/json",
          filename: "silent-regression-run-#{state.run.id}-diagnostic.json"
        )

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  defp monitor_prop(monitor) do
    version = monitor.active_version

    %{
      id: monitor.id,
      name: monitor.name,
      description: monitor.description,
      state: monitor.state,
      cadence: monitor.cadence,
      provider: version && version.provider,
      requested_model: version && version.requested_model,
      version: version && version.version
    }
  end

  defp baseline_prop(nil), do: nil

  defp baseline_prop(baseline) do
    %{
      id: baseline.id,
      status: baseline.status,
      approval_mode: baseline.approval_mode,
      approved_at: baseline.approved_at,
      provider: baseline.provider,
      requested_model: baseline.requested_model,
      monitor_fingerprint: baseline.monitor_fingerprint,
      contract_fingerprint: baseline.contract_fingerprint
    }
  end
end
