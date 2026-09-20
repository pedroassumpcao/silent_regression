defmodule SilentRegression.ContractAuthoring.RescorerTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Baselines
  alias SilentRegression.Captures.{CaptureEvaluation, ProviderAttempt}
  alias SilentRegression.ContractAuthoring
  alias SilentRegression.ContractAuthoring.{RescoreSummary, Templates}
  alias SilentRegression.MonitorOperations
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

    assert {:ok, approved} = ContractAuthoring.approve(scope, fixture.monitor.id)
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

    assert {:ok, corrected} = ContractAuthoring.approve(scope, fixture.monitor.id)
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
    {:ok, approved} = ContractAuthoring.approve(scope, fixture.monitor.id)
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
    assert {:ok, approved} = ContractAuthoring.approve(scope, fixture.monitor.id)

    evaluation = Repo.get_by!(CaptureEvaluation, contract_version_id: approved.id)
    assert evaluation.contract_status == :pass
    assert evaluation.case_expectation_status == :pass
    assert evaluation.status == :pass
    assert evaluation.case_expectation_fingerprint == case_version.expectation_fingerprint

    assert get_in(evaluation.case_expectation_results, ["checks", Access.at(0), "check_id"]) ==
             "route"
  end
end
