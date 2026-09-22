defmodule SilentRegression.GuidedFirstRunTest do
  use SilentRegression.DataCase, async: true
  use Oban.Testing, repo: SilentRegression.Repo
  import SilentRegression.GuidedSetupsFixtures
  import SilentRegression.WorkspacesFixtures
  alias SilentRegression.Accounts.Scope

  alias SilentRegression.{
    Audit,
    Baselines,
    Captures,
    ContractAuthoring,
    GuidedSetups,
    MonitorOperations,
    Monitors,
    ProductAnalytics,
    Repo,
    RunResults
  }

  alias SilentRegression.GuidedSetups.FirstRun
  alias SilentRegression.Captures.CaptureRun

  setup do
    %{scope: workspace_scope_fixture()}
  end

  test "read-only state leads through separate approval and bounded authorization, resuming duplicate attempts",
       %{scope: scope} do
    draft = sealed(scope)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    assert state.original?
    refute state.baseline.preflight.ready?
    assert Repo.aggregate(CaptureRun, :count) == 0
    assert {:error, :stale_review} = FirstRun.approve_checks(scope, draft.monitor_id, %{})
    assert {:ok, _} = FirstRun.approve_checks(scope, draft.monitor_id, check_identity(state))
    assert {:ok, _} = FirstRun.validate_model(scope, draft.monitor_id)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    attrs = authorization(state)
    assert state.baseline.preflight.planned_call_count == 2
    assert state.baseline.preflight.maximum_call_count == 4

    assert {:error, :authorization_required} =
             FirstRun.authorize(scope, draft.monitor_id, Map.delete(attrs, "confirmed"))

    assert {:error, :stale_preflight} =
             FirstRun.authorize(scope, draft.monitor_id, %{
               attrs
               | "preview_fingerprint" => "stale"
             })

    assert {:ok, first} = FirstRun.authorize(scope, draft.monitor_id, attrs)

    assert {:ok, duplicate} =
             FirstRun.authorize(scope, draft.monitor_id, %{
               attrs
               | "authorization_key" => Ecto.UUID.generate()
             })

    assert first.id == duplicate.id
    assert Repo.aggregate(CaptureRun, :count) == 1
    assert length(all_enqueued(worker: SilentRegression.Captures.Workers.ObservationWorker)) == 2

    assert Enum.count(Audit.list_workspace_events(scope), &(&1.action == "baseline.authorized")) ==
             1
  end

  test "one passing capture is reviewed, approved and activated atomically without another run or recurring schedule",
       %{scope: scope} do
    {draft, snapshot} = authorized(scope)
    complete(snapshot)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    assert state.can_finish?
    refute state.reviewed?
    assert {:error, :stale_review} = FirstRun.finish(scope, draft.monitor_id, %{})
    attrs = review_identity(state)
    assert {:ok, approved} = FirstRun.finish(scope, draft.monitor_id, attrs)
    assert approved.status == :approved
    assert {:ok, monitor} = Monitors.get_monitor(scope, draft.monitor_id)
    assert monitor.state == :active
    assert monitor.cadence == :manual
    assert is_nil(monitor.next_run_at)
    assert Repo.aggregate(CaptureRun, :count) == 1
    assert {:ok, _} = FirstRun.finish(scope, draft.monitor_id, attrs)
    events = ProductAnalytics.list_events(scope)
    assert Enum.count(events, &(&1.name == "guided_setup.results_reviewed")) == 1
    assert Enum.count(events, &(&1.name == "monitor.activated")) == 1
    refute Enum.any?(events, &(&1.name == "schedule.activated"))
    actions = Enum.map(Audit.list_workspace_events(scope), & &1.action)
    assert "baseline.approved" in actions
    assert "monitor.schedule_configured" in actions
    {:ok, overview} = RunResults.get_monitor_overview(scope, draft.monitor_id)
    assert [%{run: %{kind: :baseline}}] = overview.runs
    funnel = ProductAnalytics.activation_funnel(scope)
    assert funnel.first_capture_completed_at
    assert funnel.first_guided_result_reviewed_at
    assert funnel.first_monitor_activated_at
    assert is_nil(funnel.first_later_run_completed_at)
    assert is_nil(funnel.first_recurring_enabled_at)
    assert {:ok, _} = MonitorOperations.configure(scope, draft.monitor_id, %{cadence: :weekly})
    assert {:ok, _} = FirstRun.finish(scope, draft.monitor_id, attrs)
    {:ok, monitor} = Monitors.get_monitor(scope, draft.monitor_id)
    assert monitor.cadence == :weekly
    assert {:ok, _} = MonitorOperations.pause(scope, draft.monitor_id)
    assert {:ok, _} = FirstRun.finish(scope, draft.monitor_id, attrs)
    {:ok, monitor} = Monitors.get_monitor(scope, draft.monitor_id)
    assert monitor.state == :paused
  end

  test "failure review is durable, cannot normally finish, and retry rejects only the displayed capture",
       %{scope: scope} do
    {draft, snapshot} = authorized(scope, "[fake:output=rejected]")
    complete(snapshot)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    refute state.can_finish?
    assert state.baseline.health.contract_evaluation_counts.pass == 2
    assert state.baseline.health.case_expectation_counts.fail == 1
    attrs = review_identity(state)
    assert {:error, :result_not_approvable} = FirstRun.finish(scope, draft.monitor_id, attrs)
    assert {:ok, _} = FirstRun.review(scope, draft.monitor_id, attrs)
    assert {:ok, _} = FirstRun.review(scope, draft.monitor_id, attrs)
    assert {:ok, _} = FirstRun.reject(scope, draft.monitor_id, attrs)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    assert is_nil(state.baseline.snapshot)
    assert {:ok, retry} = FirstRun.authorize(scope, draft.monitor_id, authorization(state))
    refute retry.id == snapshot.id
    assert {:error, :stale_review} = FirstRun.reject(scope, draft.monitor_id, attrs)
    assert {:error, :stale_review} = FirstRun.finish(scope, draft.monitor_id, attrs)
    {:ok, overview} = RunResults.get_monitor_overview(scope, draft.monitor_id)
    assert length(overview.runs) == 2

    assert Enum.count(
             ProductAnalytics.list_events(scope),
             &(&1.name == "guided_setup.results_reviewed")
           ) == 1
  end

  test "provider failures and incomplete outputs remain operational blockers", %{scope: scope} do
    for marker <- ["[fake:provider-failure]", "[fake:incomplete]"] do
      {draft, snapshot} = authorized(scope, marker)
      complete(snapshot)
      {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
      refute state.can_finish?
      assert state.baseline.health.operational_blockers != []

      assert {:error, :result_not_approvable} =
               FirstRun.finish(scope, draft.monitor_id, review_identity(state))
    end
  end

  test "members inspect and review, but cannot approve, authorize, retry or activate; other workspaces see nothing",
       %{scope: scope} do
    {draft, snapshot} = authorized(scope)
    complete(snapshot)
    member = invite_and_accept_member(scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
    {:ok, state} = FirstRun.get_state(member_scope, draft.monitor_id)
    assert {:ok, _} = FirstRun.review(member_scope, draft.monitor_id, review_identity(state))

    for result <- [
          FirstRun.approve_checks(member_scope, draft.monitor_id, %{}),
          FirstRun.authorize(member_scope, draft.monitor_id, %{}),
          FirstRun.validate_model(member_scope, draft.monitor_id),
          FirstRun.finish(member_scope, draft.monitor_id, review_identity(state)),
          FirstRun.reject(member_scope, draft.monitor_id, review_identity(state))
        ] do
      assert result == {:error, :owner_required}
    end

    other = workspace_scope_fixture()
    assert {:error, :not_found} = FirstRun.get_state(other, draft.monitor_id)
    assert {:error, :not_found} = FirstRun.finish(other, draft.monitor_id, review_identity(state))
    assert {:error, :not_found} = FirstRun.corrected_draft(other, draft.monitor_id)
  end

  test "activation failure rolls back reference approval and review event", %{scope: scope} do
    {draft, snapshot} = authorized(scope)
    complete(snapshot)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)

    assert {:ok, _} =
             SilentRegression.ProviderCredentials.revoke_credential(
               scope,
               state.baseline.preflight.credential.id
             )

    assert {:error, _} = FirstRun.finish(scope, draft.monitor_id, review_identity(state))
    {:ok, current} = Baselines.get_state(scope, draft.monitor_id)
    assert current.snapshot.status == :pending

    refute Enum.any?(
             ProductAnalytics.list_events(scope),
             &(&1.name == "guided_setup.results_reviewed")
           )
  end

  test "correction copies raw authoring only and clears proof, without mutating immutable history",
       %{scope: scope} do
    draft = sealed(scope)
    assert {:ok, correction} = FirstRun.corrected_draft(scope, draft.monitor_id)
    assert correction.raw == draft.raw
    assert correction.reviews == %{}
    assert is_nil(correction.monitor_id)
    assert is_nil(correction.sealed_at)
    {:ok, original} = GuidedSetups.get(scope, draft.id)
    assert original == draft
  end

  test "changed advanced rules cannot be silently approved by the original guided proof", %{
    scope: scope
  } do
    draft = sealed(scope)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)

    root =
      put_in(state.contract.contract_version.root, ["rules", Access.at(0), "allowed_values"], [
        "other",
        "changed"
      ])

    assert {:ok, _} =
             ContractAuthoring.save_draft(scope, draft.monitor_id, %{
               template_key: "classification",
               assistance_mode: "self_serve",
               root: root
             })

    {:ok, changed} = FirstRun.get_state(scope, draft.monitor_id)
    refute changed.original?

    assert {:error, :advanced_configuration} =
             FirstRun.approve_checks(scope, draft.monitor_id, check_identity(changed))
  end

  defp sealed(scope, marker \\ "") do
    draft = draft_fixture(scope)

    raw =
      put_in(
        draft.raw,
        ["cases", Access.at(1), "variables", "action"],
        "[fake:output=rejected] deny"
      )

    raw = put_in(raw, ["cases", Access.at(0), "variables", "action"], marker <> " allow")
    {:ok, draft} = GuidedSetups.save(scope, draft.id, draft.revision, raw)
    {:ok, draft} = GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))
    {:ok, sealed} = GuidedSetups.seal(scope, draft.id, draft.revision)
    sealed
  end

  test "fixture edits invalidate displayed owner approval even when rule semantics stay the same",
       %{scope: scope} do
    draft = sealed(scope)
    {:ok, before} = FirstRun.get_state(scope, draft.monitor_id)
    fixture = hd(before.contract.fixtures)

    assert {:ok, _} =
             ContractAuthoring.update_fixture(scope, draft.monitor_id, fixture.id, %{
               name: "Updated review example",
               output_text: "approved",
               expected_status: "pass",
               expected_failed_rule_ids: []
             })

    assert {:error, :stale_review} =
             FirstRun.approve_checks(scope, draft.monitor_id, check_identity(before))

    assert Repo.aggregate(CaptureRun, :count) == 0
  end

  test "advanced semantic revisions invalidate guided finish for a previously passing capture", %{
    scope: scope
  } do
    {draft, snapshot} = authorized(scope)
    complete(snapshot)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    {:ok, _} = ContractAuthoring.create_revision(scope, draft.monitor_id)

    root =
      put_in(state.contract.contract_version.root, ["rules", Access.at(0), "allowed_values"], [
        "approved",
        "rejected",
        "maybe"
      ])

    {:ok, _} =
      ContractAuthoring.save_draft(scope, draft.monitor_id, %{
        template_key: "classification",
        assistance_mode: "self_serve",
        root: root
      })

    assert {:error, :advanced_configuration} =
             FirstRun.finish(scope, draft.monitor_id, review_identity(state))

    {:ok, current} = Baselines.get_state(scope, draft.monitor_id)
    assert current.snapshot.status == :pending
  end

  defp authorized(scope, marker \\ "") do
    draft = sealed(scope, marker)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    {:ok, _} = FirstRun.approve_checks(scope, draft.monitor_id, check_identity(state))
    {:ok, _} = FirstRun.validate_model(scope, draft.monitor_id)
    {:ok, state} = FirstRun.get_state(scope, draft.monitor_id)
    {:ok, snapshot} = FirstRun.authorize(scope, draft.monitor_id, authorization(state))
    {draft, snapshot}
  end

  defp complete(snapshot) do
    Enum.each(snapshot.capture_run.observations, fn observation ->
      Captures.execute_observation(snapshot.capture_run_id, observation.id)
    end)
  end

  defp check_identity(state),
    do: %{
      "contract_id" => state.contract.contract_version.id,
      "fingerprint" => state.contract.contract_version.fingerprint,
      "coverage_fingerprint" => state.contract.coverage.fingerprint
    }

  defp authorization(state),
    do: %{
      "authorization_key" => Ecto.UUID.generate(),
      "preview_fingerprint" => state.baseline.preflight.preview_fingerprint,
      "confirmed" => true
    }

  defp review_identity(state),
    do: %{
      "snapshot_id" => state.baseline.snapshot.id,
      "review_fingerprint" => state.review_fingerprint,
      "confirmed" => true
    }
end
