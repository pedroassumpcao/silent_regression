defmodule SilentRegressionWeb.AppController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Workspaces

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
    workspace = conn.assigns.current_scope.workspace

    conn
    |> assign(:page_title, "Product foundation")
    |> render_inertia("Dashboard", %{
      release_stage: "Private alpha",
      foundation_status: "Workspace access is isolated",
      workspace: %{name: workspace.name, slug: workspace.slug}
    })
  end
end
