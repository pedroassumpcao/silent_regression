defmodule SilentRegressionWeb.GuidedDemoControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.ProductAnalytics

  test "renders the credential-free sealed scenario inside an authorized workspace", %{
    conn: conn
  } do
    accepted = accepted_workspace_fixture(%{workspace_slug: "demo-workspace"})

    page = conn |> log_in_user(accepted.user) |> get(~p"/app/#{accepted.workspace.slug}/demo")

    assert inertia_component(page) == "Demo/Show"
    assert inertia_props(page).scenario.providerCalls == 0
    assert inertia_props(page).scenario.reference.overallStatus == "pass"
    assert inertia_props(page).scenario.recurring.contractStatus == "pass"
    assert inertia_props(page).scenario.recurring.caseExpectationStatus == "fail"
    assert inertia_props(page).progress.status == :not_started
  end

  test "persists ordered, resumable progress without creating a monitor", %{conn: conn} do
    accepted = accepted_workspace_fixture(%{workspace_slug: "guided-progress"})
    path = ~p"/app/#{accepted.workspace.slug}/demo"

    started = conn |> log_in_user(accepted.user) |> post(path <> "/start")
    assert redirected_to(started) == path

    out_of_order = post(recycle(started), path <> "/steps/expectation")
    assert Phoenix.Flash.get(out_of_order.assigns.flash, :error) =~ "current demo step"

    final_conn =
      Enum.reduce(~w(request expectation reference incident), recycle(out_of_order), fn step,
                                                                                        conn ->
        result = post(conn, path <> "/steps/#{step}")
        assert redirected_to(result) == path
        recycle(result)
      end)

    page = get(final_conn, path)
    assert inertia_props(page).progress.status == :completed
    assert inertia_props(page).progress.completedCount == 4
    scope = Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
    assert ProductAnalytics.demo_funnel(scope).completed_count == 1
  end

  test "requires authentication and workspace membership", %{conn: conn} do
    accepted = accepted_workspace_fixture(%{workspace_slug: "member-demo"})
    other = accepted_workspace_fixture(%{workspace_slug: "other-demo"})

    assert get(build_conn(), ~p"/app/#{accepted.workspace.slug}/demo")
           |> redirected_to() == ~p"/users/log-in"

    unauthorized =
      conn
      |> log_in_user(accepted.user)
      |> get(~p"/app/#{other.workspace.slug}/demo")

    assert response(unauthorized, 404) == "Not found"
  end
end
