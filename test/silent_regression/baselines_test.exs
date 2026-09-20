defmodule SilentRegression.BaselinesTest do
  use SilentRegression.DataCase, async: true
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Baselines
  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.ContractAuthoring
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.ContractAuthoring.Templates
  alias SilentRegression.ContractAuthoring.Workers.RescoreWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.Monitors
  alias SilentRegression.Repo

  setup do
    scope = workspace_scope_fixture()
    %{scope: scope}
  end

  describe "preflight and authorization" do
    test "shows an exact bounded spend preview and requires model-specific access", %{
      scope: scope
    } do
      fixture = approved_contract_fixture(scope)

      assert {:ok, blocked} = Baselines.preflight(scope, fixture.monitor.id)
      refute blocked.ready?
      assert Enum.any?(blocked.blockers, &(&1.code == "model_access_unverified"))

      assert {:ok, ready} = Baselines.validate_model_access(scope, fixture.monitor.id)
      assert ready.ready?
      assert ready.samples_per_case == 1
      assert ready.retry_limit == 1
      assert ready.planned_call_count == 1
      assert ready.maximum_call_count == 2
      assert ready.max_output_tokens_per_call == 256
      assert ready.maximum_output_tokens == 512
      assert ready.preview_fingerprint =~ ~r/^[0-9a-f]{64}$/

      assert {:ok, five_samples} =
               Baselines.preflight(scope, fixture.monitor.id, %{samples_per_case: 5})

      assert five_samples.ready?
      assert five_samples.planned_call_count == 5
      assert five_samples.maximum_call_count == 10
      assert five_samples.maximum_output_tokens == 2_560
      refute five_samples.preview_fingerprint == ready.preview_fingerprint
    end

    test "owners authorize once and the durable authorization gates baseline jobs", %{
      scope: scope
    } do
      {fixture, preflight} = ready_fixture(scope)
      authorization_key = Ecto.UUID.generate()
      attrs = authorization_attrs(preflight, authorization_key)

      assert {:ok, snapshot} = Baselines.authorize(scope, fixture.monitor.id, attrs)
      assert snapshot.status == :pending
      assert snapshot.capture_run.status == :queued
      assert snapshot.capture_run.kind == :baseline
      assert snapshot.monitor_version_id == fixture.version.id
      assert snapshot.contract_version_id == fixture.contract.id
      assert snapshot.planned_call_count == 1
      assert snapshot.maximum_call_count == 2

      assert {:ok, monitor} = Monitors.get_monitor(scope, fixture.monitor.id)
      assert monitor.state == :baseline_pending
      assert monitor.active_version_id == fixture.version.id
      assert monitor.draft_version_id == nil

      assert [%Oban.Job{args: args}] = all_enqueued(worker: ObservationWorker)
      assert Map.keys(args) |> Enum.sort() == ["capture_run_id", "observation_id"]

      assert {:ok, duplicate} = Baselines.authorize(scope, fixture.monitor.id, attrs)
      assert duplicate.id == snapshot.id
      assert length(all_enqueued(worker: ObservationWorker)) == 1

      assert {:ok, changed_preview} =
               Baselines.preflight(scope, fixture.monitor.id, %{samples_per_case: 2})

      assert {:error, :identity_conflict} =
               Baselines.authorize(
                 scope,
                 fixture.monitor.id,
                 authorization_attrs(changed_preview, authorization_key)
               )

      actions = scope |> Audit.list_workspace_events() |> Enum.map(& &1.action)
      assert "baseline.authorized" in actions
      assert Enum.count(actions, &(&1 == "monitor.baseline_prepared")) == 1
    end

    test "members inspect baseline state but cannot spend or decide", %{scope: owner_scope} do
      {fixture, preflight} = ready_fixture(owner_scope)
      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      assert {:ok, %{preflight: %{ready?: true}}} =
               Baselines.get_state(member_scope, fixture.monitor.id)

      assert {:error, :owner_required} =
               Baselines.validate_model_access(member_scope, fixture.monitor.id)

      assert {:error, :owner_required} =
               Baselines.authorize(
                 member_scope,
                 fixture.monitor.id,
                 authorization_attrs(preflight)
               )

      assert {:error, :owner_required} =
               Baselines.approve(member_scope, fixture.monitor.id, %{approval_mode: :normal})

      assert {:error, :owner_required} = Baselines.reject(member_scope, fixture.monitor.id)
    end

    test "baseline state is isolated by workspace", %{scope: scope} do
      {fixture, _preflight} = ready_fixture(scope)
      other_scope = workspace_scope_fixture()

      assert {:error, :not_found} = Baselines.get_state(other_scope, fixture.monitor.id)
      assert {:error, :not_found} = Baselines.current_approved(other_scope, fixture.monitor.id)
    end
  end

  describe "approval" do
    test "normal approval seals exact passing observations and audit evidence", %{scope: scope} do
      {fixture, snapshot} = authorized_snapshot(scope)
      complete_capture(snapshot)

      assert {:ok, state} = Baselines.get_state(scope, fixture.monitor.id)
      assert state.health.terminal?
      assert state.health.normal_approvable?
      assert state.health.deterministic_failure_count == 0
      assert state.health.observation_count == 1
      assert state.compatibility.compatible?

      assert {:ok, approved} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

      assert approved.status == :approved
      assert approved.approval_mode == :normal
      assert approved.approval_rationale == nil
      assert approved.approved_at
      assert [member] = approved.members
      assert member.capture_observation_id == hd(approved.capture_run.observations).id
      assert member.case_version_id == hd(fixture.version.cases).id
      assert member.sample_index == 0
      assert member.request_fingerprint =~ ~r/^[0-9a-f]{64}$/

      assert {:ok, current} = Baselines.current_approved(scope, fixture.monitor.id)
      assert current.id == approved.id

      event =
        scope
        |> Audit.list_workspace_events()
        |> Enum.find(&(&1.action == "baseline.approved"))

      assert event.target_id == approved.id
      assert event.metadata["approval_mode"] == "normal"
      assert event.metadata["member_count"] == 1

      assert {:ok, compatible} = Baselines.current_compatible(scope, fixture.monitor.id)
      assert compatible.id == approved.id
    end

    test "deterministic failures require a bounded exceptional rationale", %{scope: scope} do
      {fixture, snapshot} =
        authorized_snapshot(scope, %{
          cases: [case_with_context("[fake:output=maybe] Unsupported answer")]
        })

      complete_capture(snapshot)

      assert {:ok, state} = Baselines.get_state(scope, fixture.monitor.id)
      refute state.health.normal_approvable?
      assert state.health.exceptional_approvable?
      assert state.health.deterministic_failure_count == 1

      assert {:error, {:approval_blocked, blockers}} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

      assert Enum.any?(blockers, &(&1.code == "deterministic_failures"))

      assert {:error, %Ecto.Changeset{} = changeset} =
               Baselines.approve(scope, fixture.monitor.id, %{
                 approval_mode: :exceptional,
                 approval_rationale: "too short"
               })

      assert "should be at least 20 character(s)" in errors_on(changeset).approval_rationale

      rationale = "Known label variance is acceptable for this frozen baseline."

      assert {:ok, approved} =
               Baselines.approve(scope, fixture.monitor.id, %{
                 approval_mode: :exceptional,
                 approval_rationale: rationale
               })

      assert approved.approval_mode == :exceptional
      assert approved.approval_rationale == rationale
    end

    test "exceptional approval never overrides provider or model-integrity failures", %{
      scope: scope
    } do
      {provider_fixture, provider_snapshot} =
        authorized_snapshot(scope, %{
          cases: [case_with_context("[fake:provider-failure] Provider unavailable")]
        })

      complete_capture(provider_snapshot)

      assert {:ok, provider_state} = Baselines.get_state(scope, provider_fixture.monitor.id)

      assert Enum.any?(
               provider_state.health.operational_blockers,
               &(&1.code == "provider_outcomes_incomplete")
             )

      assert {:error, {:approval_blocked, provider_blockers}} =
               Baselines.approve(scope, provider_fixture.monitor.id, exceptional_approval())

      assert Enum.any?(provider_blockers, &(&1.code == "provider_outcomes_incomplete"))

      {model_fixture, model_snapshot} =
        authorized_snapshot(scope, %{
          cases: [case_with_context("[fake:model-mismatch] Model mismatch")]
        })

      complete_capture(model_snapshot)

      assert {:ok, model_state} = Baselines.get_state(scope, model_fixture.monitor.id)
      assert model_state.health.model_mismatch_count == 1

      assert {:error, {:approval_blocked, model_blockers}} =
               Baselines.approve(scope, model_fixture.monitor.id, exceptional_approval())

      assert Enum.any?(model_blockers, &(&1.code == "returned_model_mismatch"))
    end

    test "behavior changes after authorization make the pending baseline incompatible", %{
      scope: scope
    } do
      {fixture, snapshot} = authorized_snapshot(scope)
      complete_capture(snapshot)

      assert {:ok, _candidate} =
               Monitors.create_version(
                 scope,
                 fixture.monitor.id,
                 valid_version_attributes(%{system_prompt: "Changed behavior after capture."})
               )

      assert {:ok, state} = Baselines.get_state(scope, fixture.monitor.id)
      refute state.compatibility.compatible?
      assert :monitor_version_fingerprint in state.compatibility.mismatches

      assert {:error, :incompatible_baseline} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})
    end

    test "current compatibility requires an approved snapshot for the exact active behavior", %{
      scope: scope
    } do
      fixture = baseline_ready_monitor_fixture(scope)

      assert {:error, :baseline_required} =
               Baselines.current_compatible(scope, fixture.monitor.id)

      {fixture, snapshot} = authorized_snapshot(scope)
      complete_capture(snapshot)

      assert {:ok, _approved} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

      assert {:ok, _candidate} =
               Monitors.create_version(
                 scope,
                 fixture.monitor.id,
                 valid_version_attributes(%{system_prompt: "Changed after approval."})
               )

      assert {:error, :incompatible_baseline} =
               Baselines.current_compatible(scope, fixture.monitor.id)
    end

    test "an incompatible approved baseline can be replaced without losing its history", %{
      scope: scope
    } do
      fixture = operational_monitor_fixture(scope)
      original = fixture.baseline

      corrected_contract = approve_semantic_contract_revision(scope, fixture.monitor.id)

      refute corrected_contract.contract_fingerprint ==
               fixture.contract.contract_fingerprint

      assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()

      assert {:ok, state} = Baselines.get_state(scope, fixture.monitor.id)
      assert state.snapshot.id == original.id
      assert state.snapshot.status == :approved
      refute state.compatibility.compatible?
      assert state.preflight.replacement?
      assert state.preflight.ready?

      assert {:ok, replacement} =
               Baselines.authorize(
                 scope,
                 fixture.monitor.id,
                 authorization_attrs(state.preflight)
               )

      assert replacement.id != original.id
      assert replacement.status == :pending
      assert Repo.get!(BaselineSnapshot, original.id).status == :approved

      assert {:ok, monitor} = Monitors.get_monitor(scope, fixture.monitor.id)
      assert monitor.state == :baseline_pending
      assert monitor.pause_reason == nil
      assert monitor.next_run_at == nil

      complete_capture(replacement)

      assert {:ok, approved_replacement} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

      superseded = Repo.get!(BaselineSnapshot, original.id)
      assert superseded.status == :superseded
      assert superseded.superseded_by_id == approved_replacement.id
      assert superseded.superseded_at

      assert {:ok, current} = Baselines.current_compatible(scope, fixture.monitor.id)
      assert current.id == approved_replacement.id
      assert current.contract_version_id == corrected_contract.id
    end

    test "rejecting a pending capture cancels it and permits a new authorization", %{scope: scope} do
      {fixture, snapshot} = authorized_snapshot(scope)

      assert {:ok, rejected} = Baselines.reject(scope, fixture.monitor.id)
      assert rejected.status == :rejected
      assert rejected.rejected_at
      assert rejected.capture_run.status == :cancelled

      assert {:ok, next_preflight} = Baselines.preflight(scope, fixture.monitor.id)
      assert next_preflight.ready?

      assert {:ok, replacement} =
               Baselines.authorize(
                 scope,
                 fixture.monitor.id,
                 authorization_attrs(next_preflight)
               )

      assert replacement.id != snapshot.id
      assert replacement.status == :pending
    end
  end

  defp ready_fixture(scope, attrs \\ %{}) do
    fixture = approved_contract_fixture(scope, attrs)
    assert {:ok, preflight} = Baselines.validate_model_access(scope, fixture.monitor.id)
    {fixture, preflight}
  end

  defp authorized_snapshot(scope, attrs \\ %{}) do
    {fixture, preflight} = ready_fixture(scope, attrs)

    assert {:ok, snapshot} =
             Baselines.authorize(scope, fixture.monitor.id, authorization_attrs(preflight))

    {fixture, snapshot}
  end

  defp authorization_attrs(preflight, key \\ Ecto.UUID.generate()) do
    %{
      authorization_key: key,
      samples_per_case: preflight.samples_per_case,
      preview_fingerprint: preflight.preview_fingerprint
    }
  end

  defp complete_capture(snapshot) do
    Enum.each(snapshot.capture_run.observations, fn observation ->
      assert :ok =
               perform_job(ObservationWorker, %{
                 capture_run_id: snapshot.capture_run_id,
                 observation_id: observation.id
               })
    end)
  end

  defp approve_semantic_contract_revision(scope, monitor_id) do
    assert {:ok, _draft} = ContractAuthoring.create_revision(scope, monitor_id)
    assert {:ok, template} = Templates.fetch("classification")

    changed_root =
      put_in(
        template,
        ["root", "rules", Access.at(0), "allowed_values"],
        ["approved", "accepted", "rejected"]
      )["root"]

    assert {:ok, _draft} =
             ContractAuthoring.save_draft(scope, monitor_id, %{
               template_key: "classification",
               assistance_mode: "self_serve",
               root: changed_root
             })

    assert {:ok, state} = ContractAuthoring.get_state(scope, monitor_id)

    Enum.each(state.fixtures, fn contract_fixture ->
      expected =
        if contract_fixture.output_text == "approved" do
          %{expected_status: "pass", expected_failed_rule_ids: []}
        else
          %{expected_status: "fail", expected_failed_rule_ids: ["allowed_label"]}
        end

      assert {:ok, _fixture} =
               ContractAuthoring.update_fixture(
                 scope,
                 monitor_id,
                 contract_fixture.id,
                 Map.merge(expected, %{
                   name: contract_fixture.name,
                   output_text: contract_fixture.output_text
                 })
               )
    end)

    assert {:ok, pending} = ContractAuthoring.approve(scope, monitor_id)

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: pending.rescore_run.id,
               generation: 0
             })

    Repo.get!(ContractVersion, pending.id)
  end

  defp exceptional_approval do
    %{
      approval_mode: :exceptional,
      approval_rationale: "This deterministic failure is understood and explicitly accepted."
    }
  end

  defp case_with_context(context) do
    %{
      case_key: "case-#{System.unique_integer([:positive])}",
      name: "Baseline approval case",
      input_variables_json: ~s({"question":"Which plan includes SSO?"}),
      frozen_context: context,
      status: "active"
    }
  end
end
