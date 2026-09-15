defmodule SilentRegressionWeb.BaselineControllerTest do
  use SilentRegressionWeb.ConnCase, async: true
  use Oban.Testing, repo: SilentRegression.Repo

  import Inertia.Testing
  import SilentRegression.ContractAuthoringFixtures

  alias SilentRegression.Baselines
  alias SilentRegression.Captures.Workers.ObservationWorker

  setup :register_and_log_in_workspace

  describe "authenticated workspace boundary" do
    test "requires login and hides malformed or foreign monitor IDs", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      fixture = approved_contract_fixture(scope)
      path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/baseline"

      logged_out = get(build_conn(), path)
      assert redirected_to(logged_out) == ~p"/users/log-in"

      other_scope = SilentRegression.WorkspacesFixtures.workspace_scope_fixture()
      other = approved_contract_fixture(other_scope)

      malformed = get(conn, ~p"/app/#{workspace.slug}/monitors/not-a-uuid/baseline")

      cross_workspace =
        malformed
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{other.monitor.id}/baseline")

      assert response(malformed, 404) == "Not found"
      assert response(cross_workspace, 404) == "Not found"
    end
  end

  describe "baseline capture and approval" do
    test "renders an exact preview without enqueueing provider work", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      fixture = approved_contract_fixture(scope)
      path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/baseline"

      page = get(conn, path)

      assert html_response(page, 200)
      assert inertia_component(page) == "Monitors/Baseline"
      assert inertia_props(page).snapshot == nil
      refute inertia_props(page).preflight.ready
      assert inertia_props(page).preflight.caseCount == 1
      assert inertia_props(page).preflight.plannedCallCount == 1
      assert inertia_props(page).preflight.maximumCallCount == 2
      assert inertia_props(page).preflight.maximumOutputTokens == 512
      assert inertia_props(page).authorizationKey =~ ~r/^[0-9a-f-]{36}$/

      assert Enum.any?(
               inertia_props(page).preflight.blockers,
               &(&1.code == "model_access_unverified")
             )

      assert [] = all_enqueued(worker: ObservationWorker)

      five_samples = get(recycle(page), path, %{"baseline" => %{"samples_per_case" => "5"}})
      assert inertia_props(five_samples).preflight.plannedCallCount == 5
      assert inertia_props(five_samples).preflight.maximumCallCount == 10
    end

    test "verifies the exact model, authorizes once, polls evidence, and seals approval", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      fixture = approved_contract_fixture(scope)
      path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/baseline"

      verified = post(conn, path <> "/validate-model")
      assert redirected_to(verified) == path

      preview = verified |> recycle() |> get(path)
      assert inertia_props(preview).preflight.ready
      assert inertia_props(preview).preflight.credential.modelAccessVerified

      authorization = %{
        "authorization_key" => inertia_props(preview).authorizationKey,
        "samples_per_case" => inertia_props(preview).preflight.samplesPerCase,
        "preview_fingerprint" => inertia_props(preview).preflight.previewFingerprint
      }

      authorized = post(recycle(preview), path <> "/authorize", %{"baseline" => authorization})
      assert redirected_to(authorized) == path

      capture_page = authorized |> recycle() |> get(path)
      assert inertia_props(capture_page).snapshot.status == :pending
      assert inertia_props(capture_page).snapshot.run.status == :queued
      assert inertia_props(capture_page).polling
      assert [%Oban.Job{args: args}] = all_enqueued(worker: ObservationWorker)

      assert :ok = perform_job(ObservationWorker, args)

      review_page = capture_page |> recycle() |> get(path)
      refute inertia_props(review_page).polling
      assert inertia_props(review_page).health.normalApprovable
      assert inertia_props(review_page).health.completionCounts.complete == 1
      assert [observation] = inertia_props(review_page).snapshot.run.observations
      assert observation.outputText == "approved"
      assert observation.evaluation.status == :pass
      assert length(observation.evaluation.ruleResults) == 3

      approved =
        post(recycle(review_page), path <> "/approve", %{
          "baseline" => %{"approval_mode" => "normal"}
        })

      assert redirected_to(approved) == path

      sealed_page = approved |> recycle() |> get(path)
      assert inertia_props(sealed_page).snapshot.status == :approved
      assert inertia_props(sealed_page).snapshot.approvalMode == :normal
      assert inertia_props(sealed_page).snapshot.memberCount == 1
      assert inertia_props(sealed_page).compatibility.compatible
    end

    test "members can inspect but owner-only mutations return clear feedback", %{
      scope: owner_scope,
      workspace: workspace
    } do
      fixture = approved_contract_fixture(owner_scope)
      assert {:ok, _preflight} = Baselines.validate_model_access(owner_scope, fixture.monitor.id)

      member = SilentRegression.WorkspacesFixtures.invite_and_accept_member(owner_scope)
      member_conn = log_in_user(build_conn(), member.user)
      path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/baseline"

      page = get(member_conn, path)
      refute inertia_props(page).canDecide
      assert inertia_props(page).preflight.ready

      denied = post(recycle(page), path <> "/authorize", %{"baseline" => %{}})
      assert redirected_to(denied) == path
      assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "Only a workspace owner"
      assert [] = all_enqueued(worker: ObservationWorker)
    end
  end
end
