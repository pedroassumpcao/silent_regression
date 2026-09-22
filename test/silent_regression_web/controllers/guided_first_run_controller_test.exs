defmodule SilentRegressionWeb.GuidedFirstRunControllerTest do
  use SilentRegressionWeb.ConnCase, async: true
  import Inertia.Testing
  import SilentRegression.WorkspacesFixtures
  import SilentRegression.GuidedSetupsFixtures
  alias SilentRegression.Accounts.Scope
  alias SilentRegression.{Captures, GuidedSetups, Repo}

  setup %{conn: conn} do
    accepted = accepted_workspace_fixture()
    scope = Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
    draft = draft_fixture(scope)

    raw =
      put_in(
        draft.raw,
        ["cases", Access.at(1), "variables", "action"],
        "[fake:output=rejected] deny"
      )

    {:ok, draft} = GuidedSetups.save(scope, draft.id, draft.revision, raw)
    {:ok, draft} = GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))
    {:ok, draft} = GuidedSetups.seal(scope, draft.id, draft.revision)

    %{
      conn: log_in_user(conn, accepted.user),
      scope: scope,
      draft: draft,
      path: "/app/#{scope.workspace.slug}/monitors/#{draft.monitor_id}/first-run"
    }
  end

  test "full HTTP journey uses exact identities and resumes in place without extra calls", %{
    conn: conn,
    path: path,
    scope: scope,
    draft: draft
  } do
    page = get(conn, path)
    assert inertia_component(page) == "Monitors/GuidedFirstRun"
    props = inertia_props(page)
    refute props.checks.approved
    assert is_nil(props.snapshot)
    identity = props.checks.identity

    response =
      post(conn, path <> "/approve-checks", %{
        identity: %{
          contract_id: identity.contractId,
          fingerprint: identity.fingerprint,
          coverage_fingerprint: identity.coverageFingerprint
        }
      })

    assert redirected_to(response) == path
    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
    assert redirected_to(post(conn, path <> "/validate-model")) == path
    props = conn |> get(path) |> inertia_props()
    assert props.preflight.ready

    response =
      post(conn, path <> "/authorize", %{
        authorization_key: props.authorizationKey,
        preview_fingerprint: props.preflight.previewFingerprint,
        confirmed: true
      })

    assert redirected_to(response) == path
    {:ok, state} = SilentRegression.GuidedSetups.FirstRun.get_state(scope, draft.monitor_id)
    snapshot = state.baseline.snapshot

    Enum.each(
      snapshot.capture_run.observations,
      &Captures.execute_observation(snapshot.capture_run_id, &1.id)
    )

    props = conn |> get(path) |> inertia_props()
    assert props.canFinish
    assert props.snapshot.terminal

    assert [
             %{expected: "approved", output: "approved", specific: :pass},
             %{expected: "rejected", output: "rejected", specific: :pass}
           ] = props.snapshot.observations

    assert hd(props.snapshot.observations).inputJson =~ "allow"
    assert hd(props.snapshot.observations).reasons != []

    response =
      post(conn, path <> "/finish", %{
        snapshot_id: props.snapshot.id,
        review_fingerprint: props.reviewFingerprint,
        confirmed: true
      })

    assert redirected_to(response) == path
    assert conn |> get(path) |> inertia_props() |> Map.fetch!(:completed)
    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 1
  end

  test "requires login, recent authentication for sensitive operations and workspace isolation",
       %{conn: conn, scope: scope, path: path} do
    assert get(build_conn(), path) |> redirected_to() == "/users/log-in"

    stale_user = %{
      scope.user
      | authenticated_at: DateTime.add(DateTime.utc_now(:second), -30, :minute)
    }

    stale_conn = log_in_user(build_conn(), stale_user)

    for action <- ~w(validate-model authorize finish) do
      assert post(stale_conn, path <> "/" <> action, %{}) |> redirected_to() == "/users/log-in"
    end

    other = workspace_scope_fixture()
    other_draft = reviewed_fixture(other)
    {:ok, other_draft} = GuidedSetups.seal(other, other_draft.id, other_draft.revision)
    foreign_path = "/app/#{scope.workspace.slug}/monitors/#{other_draft.monitor_id}/first-run"
    assert get(conn, foreign_path) |> response(404) == "Not found"

    for action <- ~w(approve-checks authorize review finish reject correct validate-model) do
      assert post(conn, foreign_path <> "/" <> action, %{identity: %{}}) |> response(404) ==
               "Not found"
    end

    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
  end

  test "early finish or forged result review is safe and actionable", %{conn: conn, path: path} do
    for action <- ~w(finish review reject) do
      denied =
        post(conn, path <> "/" <> action, %{
          confirmed: true,
          snapshot_id: Ecto.UUID.generate(),
          review_fingerprint: "fake"
        })

      assert redirected_to(denied) == path
      assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "refreshed evidence"
    end
  end

  test "correction is an explicit no-call POST and dashboard resumes guided first-run review", %{
    conn: conn,
    path: path,
    scope: scope,
    draft: draft
  } do
    dashboard = get(conn, "/app/#{scope.workspace.slug}/monitors") |> inertia_props()
    assert hd(dashboard.monitors).guidedSetup
    next = Enum.find(dashboard.activation.steps, &(!&1.complete))
    assert next.href == path
    response = post(conn, path <> "/correct")
    [correction] = GuidedSetups.list(scope)

    assert redirected_to(response) ==
             "/app/#{scope.workspace.slug}/setup-drafts/#{correction.id}/request"

    assert correction.raw == draft.raw
    assert correction.reviews == %{}
    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
  end
end
