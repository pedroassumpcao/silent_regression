defmodule SilentRegressionWeb.Plugs.FetchWorkspaceScope do
  @moduledoc """
  Resolves a workspace slug through the authenticated user's memberships and
  upgrades the user-only scope to a tenant scope.
  """

  import Plug.Conn

  alias SilentRegression.Workspaces
  alias SilentRegressionWeb.Plugs.InertiaSharedProps

  def init(opts), do: opts

  def call(conn, _opts) do
    case Workspaces.scope_for_slug(conn.assigns.current_scope, conn.path_params["workspace_slug"]) do
      {:ok, workspace_scope} ->
        conn
        |> assign(:current_scope, workspace_scope)
        |> InertiaSharedProps.assign_current_scope()

      {:error, :not_found} ->
        conn
        |> send_resp(:not_found, "Not found")
        |> halt()
    end
  end
end
