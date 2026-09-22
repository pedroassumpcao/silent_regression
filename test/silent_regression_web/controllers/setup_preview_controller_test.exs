defmodule SilentRegressionWeb.SetupPreviewControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.WorkspacesFixtures

  test "renders an isolated preview with no production setup or credential props", %{conn: conn} do
    accepted = accepted_workspace_fixture(%{workspace_slug: "setup-preview"})

    page =
      conn
      |> log_in_user(accepted.user)
      |> get(~p"/app/#{accepted.workspace.slug}/setup-preview")

    assert inertia_component(page) == "Monitors/SetupPreview"
    assert inertia_props(page).auth.workspace.id == accepted.workspace.id
    refute Map.has_key?(inertia_props(page), :credentials)
    refute Map.has_key?(inertia_props(page), :monitor)

    scope =
      SilentRegression.Accounts.Scope.for_workspace(
        accepted.user,
        accepted.workspace,
        accepted.membership
      )

    assert SilentRegression.MonitorSetups.list_summaries(scope) == []
  end

  test "requires authentication and workspace membership", %{conn: conn} do
    accepted = accepted_workspace_fixture(%{workspace_slug: "preview-member"})
    other = accepted_workspace_fixture(%{workspace_slug: "preview-other"})

    assert get(build_conn(), ~p"/app/#{accepted.workspace.slug}/setup-preview")
           |> redirected_to() == ~p"/users/log-in"

    unauthorized =
      conn
      |> log_in_user(accepted.user)
      |> get(~p"/app/#{other.workspace.slug}/setup-preview")

    assert response(unauthorized, 404) == "Not found"
  end

  test "members can inspect the simulation without gaining owner permissions", %{conn: conn} do
    owner_scope = workspace_scope_fixture(%{workspace_slug: "preview-owner"})
    member = invite_and_accept_member(owner_scope)

    page =
      conn
      |> log_in_user(member.user)
      |> get(~p"/app/#{owner_scope.workspace.slug}/setup-preview")

    assert inertia_component(page) == "Monitors/SetupPreview"
    assert inertia_props(page).auth.membership.role == :member
    assert SilentRegression.Repo.reload!(member.membership).role == :member
  end
end
