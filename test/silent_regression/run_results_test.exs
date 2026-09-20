defmodule SilentRegression.RunResultsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import Ecto.Query
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.Alert

  setup do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    %{fixture: fixture, scope: scope}
  end

  test "worker synchronization creates one explainable content alert across retries", %{
    fixture: fixture,
    scope: scope
  } do
    replace_secret(fixture.credential.id, "sk-test-output-maybe")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)

    assert :ok = perform_job(ObservationWorker, job.args)
    assert :ok = perform_job(ObservationWorker, job.args)
    assert {:ok, %{status: :synchronized, alert_count: 1}} = RunResults.sync_run(run.id)

    assert [alert] = Repo.all(from alert in Alert, where: alert.capture_run_id == ^run.id)
    assert alert.category == :contract_failure
    assert alert.severity == :critical
    assert alert.code == "deterministic_contract_failed"
    assert alert.status == :open
    assert alert.capture_evaluation_id
    assert alert.evidence["failed_rule_ids"] == ["contract", "allowed_label"]
  end

  test "groups an operational provider failure and never calls it degradation", %{
    fixture: fixture,
    scope: scope
  } do
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)

    assert [alert] = Repo.all(from alert in Alert, where: alert.capture_run_id == ^run.id)
    assert alert.category == :operational_anomaly
    assert alert.code == "provider_authentication"
    assert alert.severity == :critical
    assert alert.evidence["affected_count"] == 1
    assert alert.explanation =~ "operational anomaly"
    assert alert.explanation =~ "not a content-degradation claim"
    refute alert.title =~ "degradation"
  end

  test "creates a distinct alert when the contract passes but the case expectation fails", %{
    scope: scope
  } do
    fixture =
      operational_monitor_fixture(scope, %{
        cases: [
          %{
            case_key: "case-specific-decision",
            name: "Case-specific decision",
            input_variables_json: ~s({"question":"Which decision applies?"}),
            frozen_context: "The expected decision for this case is approved.",
            status: "active",
            expectation_json:
              ~s({"checks":[{"id":"decision","type":"label","allowed_values":["approved"]}]})
          }
        ]
      })

    replace_secret(fixture.credential.id, "sk-test-output-rejected")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)

    assert [alert] = Repo.all(from alert in Alert, where: alert.capture_run_id == ^run.id)
    assert alert.category == :case_expectation_failure
    assert alert.code == "case_expectation_failed"
    assert alert.capture_evaluation_id

    assert alert.evidence["failed_checks"] == [
             %{
               "check_id" => "decision",
               "check_type" => "label",
               "code" => "expected_label_mismatch"
             }
           ]

    evaluation =
      Repo.get!(SilentRegression.Captures.CaptureEvaluation, alert.capture_evaluation_id)

    assert evaluation.contract_status == :pass
    assert evaluation.case_expectation_status == :fail
    assert evaluation.status == :fail
  end

  test "alert access remains inside workspace scope", %{fixture: fixture, scope: scope} do
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    other_scope = workspace_scope_fixture()

    assert {:error, :not_found} = RunResults.get_alert(other_scope, alert.id)
  end

  test "alert evidence and backward lifecycle transitions are database protected", %{
    fixture: fixture,
    scope: scope
  } do
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)

    assert_raise Postgrex.Error, ~r/result alert evidence is immutable/, fn ->
      alert |> Ecto.Changeset.change(code: "rewritten") |> Repo.update!()
    end
  end

  defp jobs_for_run(run_id) do
    all_enqueued(worker: ObservationWorker)
    |> Enum.filter(&(&1.args["capture_run_id"] == run_id))
  end

  defp replace_secret(credential_id, secret) do
    ProviderCredential
    |> Repo.get!(credential_id)
    |> Ecto.Changeset.change(secret: secret)
    |> Repo.update!()
  end
end
