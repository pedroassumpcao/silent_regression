defmodule SilentRegression.ContractAuthoring.RescorerTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Baselines
  alias SilentRegression.Captures.{CaptureEvaluation, CaptureObservation, ProviderAttempt}
  alias SilentRegression.ContractAuthoring

  alias SilentRegression.ContractAuthoring.{
    ContractVersion,
    Rescorer,
    RescoreItem,
    RescoreRun,
    RescoreSummary,
    Templates
  }

  alias SilentRegression.ContractAuthoring.Workers.RescoreWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.Monitors.CaseVersion
  alias SilentRegression.Repo

  setup do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    %{fixture: fixture, scope: scope}
  end

  test "behavior-identical successor rescoring preserves the approved baseline", %{
    fixture: fixture,
    scope: scope
  } do
    provider_attempt_count = Repo.aggregate(ProviderAttempt, :count)
    original_evaluation_count = Repo.aggregate(CaptureEvaluation, :count)

    assert {:ok, draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    assert draft.contract_fingerprint == fixture.contract.contract_fingerprint

    assert {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)
    assert pending.status == :pending_rescore
    assert Repo.get!(ContractVersion, fixture.contract.id).status == :approved

    assert_enqueued(
      worker: RescoreWorker,
      args: %{rescore_run_id: pending.rescore_run.id, generation: 0}
    )

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: pending.rescore_run.id,
               generation: 0
             })

    approved = Repo.get!(ContractVersion, pending.id)
    assert approved.status == :approved
    assert Repo.get!(RescoreRun, pending.rescore_run.id).status == :succeeded
    summary = Repo.get_by!(RescoreSummary, contract_version_id: approved.id)

    assert summary.observation_count == 1
    assert summary.pass_count == 1
    assert summary.fail_count == 0
    assert summary.evaluator_error_count == 0
    refute summary.interpretation_changed
    assert summary.predecessor_contract_version_id == fixture.contract.id
    assert Repo.aggregate(ProviderAttempt, :count) == provider_attempt_count
    assert Repo.aggregate(CaptureEvaluation, :count) == original_evaluation_count + 1

    assert {:ok, compatible_baseline} =
             Baselines.current_compatible(scope, fixture.monitor.id)

    assert compatible_baseline.id == fixture.baseline.id
    assert compatible_baseline.contract_version_id == fixture.contract.id

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    assert run.contract_version_id == approved.id
    assert run.baseline_snapshot_id == fixture.baseline.id

    assert run.contract_semantics_fingerprint ==
             compatible_baseline.contract_semantics_fingerprint

    assert Baselines.capture_run_compatible?(run)
  end

  test "semantic contract correction rescores history and requires a new baseline", %{
    fixture: fixture,
    scope: scope
  } do
    provider_attempt_count = Repo.aggregate(ProviderAttempt, :count)
    {:ok, _draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    {:ok, template} = Templates.fetch("classification")

    changed_root =
      put_in(
        template,
        ["root", "rules", Access.at(0), "allowed_values"],
        ["approved", "accepted", "rejected"]
      )["root"]

    assert {:ok, _draft} =
             ContractAuthoring.save_draft(scope, fixture.monitor.id, %{
               template_key: "classification",
               assistance_mode: "self_serve",
               root: changed_root
             })

    assert {:ok, state} = ContractAuthoring.get_state(scope, fixture.monitor.id)

    Enum.each(state.fixtures, fn contract_fixture ->
      attrs =
        if contract_fixture.output_text == "approved" do
          %{
            name: contract_fixture.name,
            output_text: contract_fixture.output_text,
            expected_status: "pass",
            expected_failed_rule_ids: []
          }
        else
          %{
            name: contract_fixture.name,
            output_text: contract_fixture.output_text,
            expected_status: "fail",
            expected_failed_rule_ids: ["allowed_label"]
          }
        end

      assert {:ok, _fixture} =
               ContractAuthoring.update_fixture(
                 scope,
                 fixture.monitor.id,
                 contract_fixture.id,
                 attrs
               )
    end)

    assert {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: pending.rescore_run.id,
               generation: 0
             })

    corrected = Repo.get!(ContractVersion, pending.id)
    summary = Repo.get_by!(RescoreSummary, contract_version_id: corrected.id)

    assert summary.observation_count == 1
    assert summary.pass_count == 1
    assert summary.interpretation_changed
    assert corrected.contract_fingerprint != fixture.contract.contract_fingerprint
    assert Repo.aggregate(ProviderAttempt, :count) == provider_attempt_count

    assert {:error, :incompatible_baseline} =
             Baselines.current_compatible(scope, fixture.monitor.id)

    assert {:error, :incompatible_baseline} =
             MonitorOperations.run_now(scope, fixture.monitor.id)
  end

  test "rescore summaries are immutable", %{fixture: fixture, scope: scope} do
    {:ok, _draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: pending.rescore_run.id,
               generation: 0
             })

    approved = Repo.get!(ContractVersion, pending.id)
    summary = Repo.get_by!(RescoreSummary, contract_version_id: approved.id)

    assert_raise Postgrex.Error, ~r/contract rescore summaries are immutable/, fn ->
      summary |> Ecto.Changeset.change(pass_count: 999) |> Repo.update!()
    end
  end

  test "historical rescoring retains each observation's exact case expectation", %{scope: scope} do
    fixture =
      operational_monitor_fixture(scope, %{
        cases: [
          %{
            case_key: "case-aware-label",
            name: "Case-aware label",
            input_variables_json: ~s({"question":"Which route applies?"}),
            frozen_context: "This case should remain approved.",
            expectation_json:
              Jason.encode!(%{
                checks: [
                  %{id: "route", type: "label", allowed_values: ["approved"]}
                ]
              }),
            status: "active"
          }
        ]
      })

    [case_version] = fixture.version.cases
    assert {:ok, _draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    assert {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: pending.rescore_run.id,
               generation: 0
             })

    approved = Repo.get!(ContractVersion, pending.id)

    evaluation = Repo.get_by!(CaptureEvaluation, contract_version_id: approved.id)
    assert evaluation.contract_status == :pass
    assert evaluation.case_expectation_status == :pass
    assert evaluation.status == :pass
    assert evaluation.case_expectation_fingerprint == case_version.expectation_fingerprint

    assert get_in(evaluation.case_expectation_results, ["checks", Access.at(0), "check_id"]) ==
             "route"
  end

  test "pins an exact observation set and advances it in bounded durable batches", %{
    fixture: fixture,
    scope: scope
  } do
    [original] = fixture.baseline.capture_run.observations

    Enum.each(1..50, fn sample_index ->
      clone_successful_observation(original, sample_index)
    end)

    assert {:ok, _draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    assert {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)
    run = Repo.get!(RescoreRun, pending.rescore_run.id)

    assert run.status == :pending
    assert run.total_count == 51
    assert Repo.aggregate(Ecto.assoc(run, :items), :count) == 51
    assert Repo.get!(ContractVersion, fixture.contract.id).status == :approved

    assert {:ok, live_run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    assert live_run.contract_version_id == fixture.contract.id

    late_observation = clone_successful_observation(original, 51)

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: run.id,
               generation: 0
             })

    first_batch = Repo.get!(RescoreRun, run.id)
    assert first_batch.status == :running
    assert first_batch.processed_count == 50
    assert Repo.get!(ContractVersion, pending.id).status == :pending_rescore
    assert Repo.get!(ContractVersion, fixture.contract.id).status == :approved

    assert {:ok, pending_state} = ContractAuthoring.get_state(scope, fixture.monitor.id)
    assert pending_state.contract_version.status == :pending_rescore
    assert pending_state.approved_contract_version.id == fixture.contract.id
    assert pending_state.rescore_run.processed_count == 50

    assert_enqueued(
      worker: RescoreWorker,
      args: %{rescore_run_id: run.id, generation: 50}
    )

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: run.id,
               generation: 50
             })

    completed = Repo.get!(RescoreRun, run.id)
    assert completed.status == :succeeded
    assert completed.processed_count == 51
    assert Repo.get!(ContractVersion, pending.id).status == :approved
    assert Repo.get!(ContractVersion, fixture.contract.id).status == :retired

    refute Repo.get_by(CaptureEvaluation,
             capture_observation_id: late_observation.id,
             contract_version_id: pending.id
           )
  end

  test "a terminal worker failure seals the candidate without replacing the predecessor", %{
    fixture: fixture,
    scope: scope
  } do
    assert {:ok, _draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    assert {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)

    assert {:ok, :ok} = Rescorer.fail_infrastructure(pending.rescore_run.id, :forced_failure)

    failed = Repo.get!(ContractVersion, pending.id) |> Repo.preload(:fixtures)
    run = Repo.get!(RescoreRun, pending.rescore_run.id)

    assert failed.status == :rescore_failed
    assert run.status == :failed
    assert run.error["code"] == "rescore_worker_exhausted"
    assert Repo.get!(ContractVersion, fixture.contract.id).status == :approved
    refute Repo.get_by(RescoreSummary, contract_version_id: failed.id)

    assert {:ok, failed_state} = ContractAuthoring.get_state(scope, fixture.monitor.id)
    assert failed_state.contract_version.id == failed.id
    assert failed_state.approved_contract_version.id == fixture.contract.id
    assert failed_state.rescore_run.status == :failed

    assert {:ok, retry} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    assert retry.status == :draft
    assert retry.predecessor_id == fixture.contract.id
    assert retry.root == failed.root
    assert length(retry.fixtures) == length(failed.fixtures)
  end

  test "an evaluator error fails closed and never partially activates the candidate", %{
    fixture: fixture,
    scope: scope
  } do
    [original] = fixture.baseline.capture_run.observations

    invalid_case =
      %CaseVersion{
        id: Ecto.UUID.generate(),
        case_key: "invalid-expectation",
        name: "Invalid expectation provenance",
        position: 999,
        status: :active,
        input_variables: %{},
        frozen_context: "",
        expectation_schema_version: "case_expectation_v1",
        expectation: %{
          "checks" => [
            %{"id" => "route", "type" => "label", "allowed_values" => ["approved"]}
          ]
        },
        expectation_fingerprint: String.duplicate("0", 64),
        fingerprint: String.duplicate("1", 64),
        monitor_version_id: fixture.version.id,
        created_by_user_id: scope.user.id
      }
      |> Repo.insert!()

    invalid_observation = clone_successful_observation(original, 0, invalid_case.id)

    assert {:ok, _draft} = ContractAuthoring.create_revision(scope, fixture.monitor.id)
    assert {:ok, pending} = ContractAuthoring.approve(scope, fixture.monitor.id)

    assert :ok =
             perform_job(RescoreWorker, %{
               rescore_run_id: pending.rescore_run.id,
               generation: 0
             })

    failed = Repo.get!(ContractVersion, pending.id)
    run = Repo.get!(RescoreRun, pending.rescore_run.id)

    assert failed.status == :rescore_failed
    assert run.status == :failed
    assert run.evaluator_error_count == 1
    assert run.error["code"] == "historical_evaluator_error"
    assert run.error["observation_id"] == invalid_observation.id
    assert Repo.get!(ContractVersion, fixture.contract.id).status == :approved
    refute Repo.get_by(RescoreSummary, contract_version_id: failed.id)

    assert %RescoreItem{status: :evaluator_error, capture_evaluation_id: evaluation_id} =
             Repo.get_by!(RescoreItem,
               contract_rescore_run_id: run.id,
               capture_observation_id: invalid_observation.id
             )

    assert Repo.get!(CaptureEvaluation, evaluation_id).status == :evaluator_error
  end

  defp clone_successful_observation(original, sample_index, case_version_id \\ nil) do
    %CaptureObservation{
      id: Ecto.UUID.generate(),
      sample_index: sample_index,
      status: :succeeded,
      case_fingerprint: original.case_fingerprint,
      request_fingerprint: original.request_fingerprint,
      requested_model: original.requested_model,
      returned_model: original.returned_model,
      output_text: original.output_text,
      completion_state: original.completion_state,
      finish_reason: original.finish_reason,
      input_tokens: original.input_tokens,
      output_tokens: original.output_tokens,
      latency_ms: original.latency_ms,
      provider_request_id: "rescore-fixture-#{sample_index}",
      provider_metadata: %{},
      captured_at: original.captured_at,
      terminal_at: original.terminal_at,
      capture_run_id: original.capture_run_id,
      case_version_id: case_version_id || original.case_version_id
    }
    |> Repo.insert!()
  end
end
