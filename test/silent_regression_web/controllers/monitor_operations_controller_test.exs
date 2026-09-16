defmodule SilentRegressionWeb.MonitorOperationsControllerTest do
  use SilentRegressionWeb.ConnCase, async: true
  use Oban.Testing, repo: SilentRegression.Repo

  import Inertia.Testing
  import SilentRegression.ContractAuthoringFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.WorkspacesFixtures

  setup :register_and_log_in_workspace

  test "requires login and hides malformed or foreign monitors", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    fixture = approved_baseline_fixture(scope)
    path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/operations"

    assert redirected_to(get(build_conn(), path)) == ~p"/users/log-in"

    malformed = get(conn, ~p"/app/#{workspace.slug}/monitors/not-a-uuid/operations")
    assert response(malformed, 404) == "Not found"

    other_scope = WorkspacesFixtures.workspace_scope_fixture()
    other = approved_baseline_fixture(other_scope)

    foreign =
      malformed
      |> recycle()
      |> get(~p"/app/#{workspace.slug}/monitors/#{other.monitor.id}/operations")

    assert response(foreign, 404) == "Not found"
  end

  test "owner activates, runs, pauses, and resumes from the operations page", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    fixture = approved_baseline_fixture(scope)
    path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/operations"

    page = get(conn, path)
    assert html_response(page, 200)
    assert inertia_component(page) == "Monitors/Operations"
    assert inertia_props(page).approvedBaseline
    assert inertia_props(page).canManage
    assert inertia_props(page).monitor.state == :baseline_pending
    assert inertia_props(page).spend.maximumCallCount == 2
    assert inertia_props(page).spend.perRunCallLimit == 200
    assert inertia_props(page).spend.workspaceRunLimit == 20
    assert inertia_props(page).spend.workspaceRunsToday == 1
    assert inertia_props(page).spend.workspaceCommittedCallsToday == 2
    assert inertia_props(page).spend.resetsAt
    assert inertia_props(page).unresolvedAlerts == 0

    configured =
      patch(recycle(page), path <> "/schedule", %{"schedule" => %{"cadence" => "daily"}})

    assert redirected_to(configured) == path

    active_page = configured |> recycle() |> get(path)
    assert inertia_props(active_page).monitor.state == :active
    assert inertia_props(active_page).monitor.cadence == :daily
    assert inertia_props(active_page).monitor.nextRunAt

    queued = post(recycle(active_page), path <> "/run-now")
    assert redirected_to(queued) == path
    assert [%Oban.Job{}] = all_enqueued(worker: ObservationWorker)

    paused = post(recycle(queued), path <> "/pause")
    assert redirected_to(paused) == path

    paused_page = paused |> recycle() |> get(path)
    assert inertia_props(paused_page).monitor.state == :paused
    assert inertia_props(paused_page).monitor.pauseReason == :owner_paused
    assert inertia_props(paused_page).monitor.nextRunAt == nil

    resumed = post(recycle(paused_page), path <> "/resume")
    assert redirected_to(resumed) == path

    resumed_page = resumed |> recycle() |> get(path)
    assert inertia_props(resumed_page).monitor.state == :active
    assert inertia_props(resumed_page).monitor.cadence == :daily
    assert inertia_props(resumed_page).monitor.nextRunAt
  end

  test "members inspect durable state but cannot authorize spend or lifecycle changes", %{
    scope: owner_scope,
    workspace: workspace
  } do
    fixture = approved_baseline_fixture(owner_scope)

    assert {:ok, _monitor} =
             MonitorOperations.configure(owner_scope, fixture.monitor.id, %{cadence: :manual})

    member = WorkspacesFixtures.invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
    member_conn = log_in_user(build_conn(), member.user)
    path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/operations"

    page = get(member_conn, path)
    refute inertia_props(page).canManage
    assert inertia_props(page).monitor.state == :active

    denied = post(recycle(page), path <> "/run-now")
    assert redirected_to(denied) == path
    assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "Only a workspace owner"
    assert {:ok, state} = MonitorOperations.get_state(member_scope, fixture.monitor.id)
    assert state.last_run == nil
    assert [] = all_enqueued(worker: ObservationWorker)
  end

  test "activation reports the missing-baseline requirement without provider work", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    fixture = baseline_ready_monitor_fixture(scope)
    path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/operations"

    denied = patch(conn, path <> "/schedule", %{"schedule" => %{"cadence" => "daily"}})
    assert redirected_to(denied) == path
    assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "Approve a compatible baseline"
    assert [] = all_enqueued(worker: ObservationWorker)
  end
end
