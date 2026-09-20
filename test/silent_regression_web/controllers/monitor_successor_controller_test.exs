defmodule SilentRegressionWeb.MonitorSuccessorControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.ContractAuthoringFixtures

  alias SilentRegression.MonitorSetups

  setup :register_and_log_in_workspace

  test "an owner starts a copied successor without changing active execution", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    fixture = operational_monitor_fixture(scope)
    active_version_id = fixture.monitor.active_version_id

    response =
      post(
        conn,
        ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/successor"
      )

    assert redirected_to(response) ==
             ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/setup/review"

    assert {:ok, state} = MonitorSetups.successor_state(scope, fixture.monitor.id)
    assert state.setup.status == :in_progress
    assert state.monitor.active_version_id == active_version_id
    assert state.monitor.draft_version_id == nil

    page =
      response
      |> recycle()
      |> get(~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/successor")

    assert html_response(page, 200)
    assert inertia_component(page) == "Monitors/Successor"
    assert inertia_props(page).canActivate
    assert inertia_props(page).setup.status == :in_progress
    assert inertia_props(page).setup.sourceVersion == fixture.version.version
    assert inertia_props(page).setup.candidateVersion == nil
    refute inertia_props(page).preview.activationReady
  end

  test "successor endpoints preserve workspace tenancy", %{
    conn: conn,
    workspace: workspace
  } do
    other_scope = SilentRegression.WorkspacesFixtures.workspace_scope_fixture()
    fixture = operational_monitor_fixture(other_scope)

    response =
      get(
        conn,
        ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/successor"
      )

    assert response(response, 404) == "Not found"
  end
end
