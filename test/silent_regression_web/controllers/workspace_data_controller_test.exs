defmodule SilentRegressionWeb.WorkspaceDataControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.Workspace

  setup :register_and_log_in_workspace

  test "renders the retention policy inside an authenticated workspace", %{
    conn: conn,
    workspace: workspace
  } do
    conn = get(conn, ~p"/app/#{workspace.slug}/settings/data")

    assert html_response(conn, 200)
    assert inertia_component(conn) == "Settings/DataRetention"
    assert inertia_props(conn).canManage
    assert inertia_props(conn).policy.closedWorkspace =~ "30 days"
  end

  test "owner closes only after exact slug confirmation", %{conn: conn, workspace: workspace} do
    conn = post(conn, ~p"/app/#{workspace.slug}/settings/data/close", %{confirmation: "wrong"})
    assert redirected_to(conn) == ~p"/app/#{workspace.slug}/settings/data"
    assert Repo.get!(Workspace, workspace.id).status == :active

    conn =
      post(recycle(conn), ~p"/app/#{workspace.slug}/settings/data/close", %{
        confirmation: workspace.slug
      })

    assert redirected_to(conn) == ~p"/app"
    assert Repo.get!(Workspace, workspace.id).status == :closed
  end

  test "member can read policy but cannot mutate workspace", %{
    conn: owner_conn,
    scope: owner_scope,
    workspace: workspace
  } do
    member = invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

    conn =
      owner_conn
      |> recycle()
      |> log_in_user(member.user)
      |> get(~p"/app/#{workspace.slug}/settings/data")

    refute inertia_props(conn).canManage

    conn =
      conn
      |> recycle()
      |> post(~p"/app/#{workspace.slug}/settings/data/delete", %{confirmation: workspace.slug})

    assert response(conn, 403)
    assert Repo.get!(Workspace, workspace.id).status == :active
    assert member_scope.membership.role == :member
  end
end
