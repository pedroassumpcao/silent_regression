defmodule SilentRegressionWeb.GuidedSetupControllerTest do
  use SilentRegressionWeb.ConnCase, async: true
  import Inertia.Testing
  import SilentRegression.WorkspacesFixtures
  import SilentRegression.GuidedSetupsFixtures
  alias SilentRegression.{GuidedSetups, Repo}
  alias SilentRegression.Accounts.Scope

  setup %{conn: conn} do
    accepted = accepted_workspace_fixture()
    scope = Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)

    %{
      conn: log_in_user(conn, accepted.user),
      scope: scope,
      base: "/app/#{accepted.workspace.slug}/setup-drafts"
    }
  end

  test "starts a real saved draft without creating a monitor or exposing credentials", %{
    conn: conn,
    scope: scope,
    base: base
  } do
    assert conn |> get(base <> "/new") |> inertia_component() == "Monitors/GuidedSetupStart"
    response = post(conn, base)
    [draft] = GuidedSetups.list(scope)
    assert redirected_to(response) == base <> "/#{draft.id}/request"
    page = get(conn, redirected_to(response))
    assert inertia_component(page) == "Monitors/GuidedSetup"
    assert inertia_props(page).draft.revision == 1
    assert inertia_props(page).journey.stage == :request
    assert Repo.aggregate(SilentRegression.Monitors.Monitor, :count) == 0
  end

  test "save and exit keeps incomplete raw text and supports resume from dashboard", %{
    conn: conn,
    scope: scope,
    base: base
  } do
    {:ok, draft} = GuidedSetups.create(scope)
    raw = %{draft.raw | "nativeJson" => "{", "mode" => "native"}

    saved =
      put(conn, base <> "/#{draft.id}", %{
        raw: raw,
        revision: draft.revision,
        intent: "exit",
        step: "request"
      })

    assert redirected_to(saved) == "/app/#{scope.workspace.slug}/monitors"
    {:ok, resumed} = GuidedSetups.get(scope, draft.id)
    assert resumed.raw["nativeJson"] == "{"
    page = get(conn, redirected_to(saved))
    assert [%{id: id}] = inertia_props(page).guidedDrafts
    assert id == draft.id
  end

  for recipe <- ~w(json sources text) do
    @recipe recipe
    test "#{recipe} starts through Step 0 and retains its recipe on the first-run page", %{
      conn: conn,
      scope: scope,
      base: base
    } do
      response = post(conn, base, %{recipe: @recipe})
      [draft] = GuidedSetups.list(scope)
      assert draft.recipe == @recipe

      assert get(conn, redirected_to(response))
             |> inertia_props()
             |> Map.get(:draft)
             |> Map.get(:recipe) == @recipe

      raw = recipe_raw_fixture(scope, @recipe)

      put(conn, base <> "/#{draft.id}", %{
        raw: raw,
        revision: draft.revision,
        intent: "continue",
        step: "examples"
      })

      {:ok, draft} = GuidedSetups.get(scope, draft.id)

      post(conn, base <> "/#{draft.id}/review", %{
        revision: draft.revision,
        judgments: judgments(draft)
      })

      {:ok, draft} = GuidedSetups.get(scope, draft.id)
      response = post(conn, base <> "/#{draft.id}/seal", %{revision: draft.revision})
      page = get(conn, redirected_to(response))
      assert inertia_component(page) == "Monitors/GuidedFirstRun"
      assert inertia_props(page).recipe == @recipe
      assert inertia_props(page).checks.ready
      assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
    end
  end

  test "unknown recipe cannot create a draft", %{conn: conn, scope: scope, base: base} do
    assert post(conn, base, %{recipe: "arbitrary"}).status == 404
    assert GuidedSetups.list(scope) == []
  end

  test "server prevents skipping review, records partial proof, and seals only current fully reviewed configuration",
       %{conn: conn, scope: scope, base: base} do
    draft = draft_fixture(scope)
    path = base <> "/#{draft.id}"
    assert conn |> get(path <> "/review") |> inertia_props() |> Map.fetch!(:step) == "checks"

    partial =
      post(conn, path <> "/review", %{
        revision: draft.revision,
        judgments: Enum.take(judgments(draft), 1),
        intent: "exit"
      })

    assert redirected_to(partial) == "/app/#{scope.workspace.slug}/monitors"
    {:ok, current} = GuidedSetups.get(scope, draft.id)
    assert map_size(current.reviews) == 1
    assert GuidedSetups.state(scope, current).stage == :checks
    post(conn, path <> "/review", %{revision: current.revision, judgments: judgments(current)})
    {:ok, reviewed} = GuidedSetups.get(scope, draft.id)
    response = post(conn, path <> "/seal", %{revision: reviewed.revision})
    {:ok, sealed} = GuidedSetups.get(scope, draft.id)

    assert redirected_to(response) ==
             "/app/#{scope.workspace.slug}/monitors/#{sealed.monitor_id}/first-run"

    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
  end

  test "requires login and membership; never trusts another workspace draft ID", %{
    conn: conn,
    scope: scope,
    base: base
  } do
    assert get(build_conn(), base <> "/new") |> redirected_to() == "/users/log-in"
    other = workspace_scope_fixture()
    draft = draft_fixture(other)
    assert get(conn, base <> "/#{draft.id}") |> response(404) == "Not found"

    assert put(conn, base <> "/#{draft.id}", %{revision: draft.revision, raw: draft.raw})
           |> response(404) == "Not found"

    assert post(conn, base <> "/#{draft.id}/seal", %{revision: draft.revision}) |> response(404) ==
             "Not found"

    assert GuidedSetups.list(scope) == []
  end

  test "stale save redirects with actionable errors and leaves the saved content unchanged", %{
    conn: conn,
    scope: scope,
    base: base
  } do
    draft = draft_fixture(scope)

    {:ok, saved} =
      GuidedSetups.save(scope, draft.id, draft.revision, %{draft.raw | "name" => "Newer name"})

    response =
      conn
      |> put_req_header("x-inertia", "true")
      |> put(base <> "/#{draft.id}", %{revision: draft.revision, raw: draft.raw, step: "request"})

    assert redirected_to(response, 303) == base <> "/#{draft.id}/request"
    {:ok, current} = GuidedSetups.get(scope, draft.id)
    assert current.revision == saved.revision
    assert current.raw["name"] == "Newer name"
  end
end
