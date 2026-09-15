defmodule SilentRegressionWeb.AppController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.{MonitorSetups, Workspaces}

  def entry(conn, _params) do
    case Workspaces.default_workspace_scope(conn.assigns.current_scope) do
      {:ok, %Scope{workspace: workspace}} ->
        redirect(conn, to: "/app/#{workspace.slug}")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "No active workspace is available for this account.")
        |> redirect(to: ~p"/")
    end
  end

  def index(conn, _params) do
    render_dashboard(conn, "overview")
  end

  def monitors(conn, _params) do
    render_dashboard(conn, "monitors")
  end

  defp render_dashboard(conn, current_section) do
    scope = conn.assigns.current_scope

    conn
    |> assign(:page_title, "Monitors")
    |> render_inertia("Dashboard", %{
      current_section: current_section,
      monitors: Enum.map(MonitorSetups.list_summaries(scope), &summary_prop/1),
      release_stage: "Private alpha",
      workspace: %{name: scope.workspace.name, slug: scope.workspace.slug}
    })
  end

  defp summary_prop(%{setup: setup, progress: progress}) do
    %{
      id: setup.monitor.id,
      name: setup.monitor.name,
      description: setup.monitor.description,
      state: setup.monitor.state,
      setup_status: setup.status,
      completed_steps: progress.completed_count,
      total_steps: progress.total_count,
      progress_percent: progress.percent,
      next_step: progress.next_step,
      updated_at: setup.updated_at
    }
  end
end
