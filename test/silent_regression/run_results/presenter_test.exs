defmodule SilentRegression.RunResults.PresenterTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.Presenter

  setup do
    scope = workspace_scope_fixture()

    fixture =
      operational_monitor_fixture(scope, %{
        cases: [
          %{
            case_key: "supported-answer",
            name: "Supported answer",
            input_variables_json: ~s({"question":"Which plan includes SSO?"}),
            frozen_context: "The Enterprise plan includes SSO.",
            status: "active",
            expectation_json:
              ~s({"checks":[{"id":"decision","type":"label","allowed_values":["approved"]}]})
          }
        ]
      })

    {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    :ok = perform_job(ObservationWorker, job.args)
    {:ok, state} = RunResults.get_run_detail(scope, fixture.monitor.id, run.id)

    %{fixture: fixture, run: run, scope: scope, state: state}
  end

  test "presents explicit run counts, exact provenance, and every observation", %{state: state} do
    detail = Presenter.run_detail(state.run, state.alerts)

    assert detail.summary.planned_call_count == 1
    assert detail.summary.actual_call_count == 1
    assert detail.summary.observation_counts == %{"succeeded" => 1}
    assert detail.summary.completion_counts == %{"complete" => 1}
    assert detail.summary.evaluation_counts == %{"pass" => 1}
    assert detail.summary.contract_evaluation_counts == %{"pass" => 1}
    assert detail.summary.case_expectation_counts == %{"pass" => 1}
    assert detail.summary.provider_failure_count == 0
    assert detail.summary.provenance_compatible
    assert detail.provenance.compatible
    assert detail.provenance.baseline.id == state.run.baseline_snapshot_id

    assert detail.provenance.baseline.contract_fingerprint ==
             detail.provenance.current.contract_fingerprint

    assert [observation] = detail.observations
    assert observation.case.key == "supported-answer"
    assert observation.output.text == "approved"
    assert [attempt] = observation.attempts
    assert attempt.request_mode == :provider_native_v1
    assert attempt.request_schema_version == 1
    assert attempt.request_fingerprint == hd(state.run.observations).request_fingerprint
    assert [evaluation] = observation.evaluations
    assert evaluation.contract_status == :pass
    assert evaluation.case_expectation_status == :pass
    assert evaluation.case_expectation_schema_version == "case_expectation_v1"
    assert evaluation.case_expectation_fingerprint == observation.case.expectation_fingerprint

    assert get_in(evaluation.case_expectation_results, [:checks, Access.at(0), :check_id]) ==
             "decision"

    assert length(evaluation.rule_results) == 3

    assert Enum.map(evaluation.rule_results, &{&1.rule_id, &1.severity}) == [
             {"contract", :critical},
             {"allowed_label", :critical},
             {"label_length", :warning}
           ]
  end

  test "redacted diagnostics omit prompt, context, output, and rule evidence payloads", %{
    state: state
  } do
    diagnostic = Presenter.diagnostic(state.run, state.alerts)
    encoded = Jason.encode!(diagnostic)
    [observation] = diagnostic["observations"]
    [evaluation] = observation["evaluations"]
    [rule_result | _rest] = evaluation["rule_results"]

    assert diagnostic["schema_version"] == 1
    refute Map.has_key?(observation, "case")
    refute Map.has_key?(observation, "output")
    refute Map.has_key?(rule_result, "evidence")
    refute encoded =~ "Answer only from the supplied context"
    refute encoded =~ "The Enterprise plan includes SSO"
    refute encoded =~ "normalized_output"
    refute encoded =~ "authorization"
    refute encoded =~ "api_key"
  end

  test "monitor history and run detail queries stay workspace scoped", %{
    fixture: fixture,
    run: run,
    scope: scope
  } do
    assert {:ok, overview} = RunResults.get_monitor_overview(scope, fixture.monitor.id)
    assert Enum.any?(overview.runs, &(&1.run.kind == :baseline))
    %{run: history_run} = Enum.find(overview.runs, &(&1.run.kind == :manual))
    assert history_run.id == run.id
    assert overview.current_baseline.id == run.baseline_snapshot_id
    assert {:ok, 0} = RunResults.unresolved_alert_count(scope, fixture.monitor.id)

    other_scope = workspace_scope_fixture()

    assert {:error, :not_found} =
             RunResults.get_run_detail(other_scope, fixture.monitor.id, run.id)
  end

  defp jobs_for_run(run_id) do
    all_enqueued(worker: ObservationWorker)
    |> Enum.filter(&(&1.args["capture_run_id"] == run_id))
  end
end
