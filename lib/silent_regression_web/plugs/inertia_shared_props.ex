defmodule SilentRegressionWeb.Plugs.InertiaSharedProps do
  @moduledoc """
  Shares only the authenticated identity and tenant data that every Inertia
  page may safely receive.
  """

  import Inertia.Controller, only: [assign_prop: 3]

  alias SilentRegression.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts), do: assign_current_scope(conn)

  def assign_current_scope(conn) do
    assign_prop(conn, :auth, auth_prop(conn.assigns[:current_scope]))
  end

  defp auth_prop(nil), do: %{user: nil, workspace: nil, membership: nil}

  defp auth_prop(%Scope{} = scope) do
    %{
      user: user_prop(scope.user),
      workspace: workspace_prop(scope.workspace),
      membership: membership_prop(scope.membership)
    }
  end

  defp user_prop(nil), do: nil
  defp user_prop(user), do: %{id: user.id, email: user.email}

  defp workspace_prop(nil), do: nil

  defp workspace_prop(workspace) do
    %{id: workspace.id, name: workspace.name, slug: workspace.slug}
  end

  defp membership_prop(nil), do: nil
  defp membership_prop(membership), do: %{id: membership.id, role: membership.role}
end
