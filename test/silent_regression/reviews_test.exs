defmodule SilentRegression.ReviewsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import Ecto.Query
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Reviews
  alias SilentRegression.Reviews.ReviewDecision
  alias SilentRegression.RunResults.Alert

  setup do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    %{fixture: fixture, scope: scope}
  end

  test "records exact alert evidence and supersedes without rewriting history", %{
    fixture: fixture,
    scope: scope
  } do
    %{alert: alert, run: run} = failed_run(fixture, scope)

    assert {:ok, first} =
             Reviews.submit_review(scope, %{
               subject_kind: :alert,
               subject_id: alert.id,
               classification: :confirmed_regression,
               action: :prompt_change,
               rationale: "The contract caught a real label regression."
             })

    assert first.workspace_id == scope.workspace.id
    assert first.monitor_id == fixture.monitor.id
    assert first.capture_run_id == run.id
    assert first.result_alert_id == alert.id
    assert first.capture_evaluation_id == alert.capture_evaluation_id
    assert first.contract_version_id == run.contract_version_id
    assert first.baseline_snapshot_id == run.baseline_snapshot_id
    assert first.reviewer_user_id == scope.user.id
    assert first.supersedes_id == nil

    assert {:error, :stale_review} =
             Reviews.submit_review(scope, %{
               subject_kind: :alert,
               subject_id: alert.id,
               classification: :acceptable_variation
             })

    assert {:ok, corrected} =
             Reviews.submit_review(scope, %{
               subject_kind: :alert,
               subject_id: alert.id,
               expected_current_id: first.id,
               classification: :acceptable_variation,
               action: :contract_revision,
               rationale: "This phrasing is valid and the contract is too narrow."
             })

    assert corrected.supersedes_id == first.id
    assert Repo.get!(ReviewDecision, first.id).classification == :confirmed_regression

    assert {:ok, review_state} = Reviews.list_run_reviews(scope, run.id)
    assert review_state.summary.current_count == 1
    assert review_state.summary.superseded_count == 1
    assert review_state.summary.changed_judgment_count == 1
    assert review_state.summary.classification_counts == %{acceptable_variation: 1}
    assert review_state.summary.action_counts == %{contract_revision: 1}

    assert [%{decision: ^first, current?: false}, %{decision: ^corrected, current?: true}] =
             review_state.decisions
  end

  test "captures a missed regression on an observation without an alert", %{
    fixture: fixture,
    scope: owner_scope
  } do
    %{run: run} = passing_run(fixture, owner_scope)
    [observation] = run.observations
    [evaluation] = observation.evaluations
    assert evaluation.status == :pass

    member = invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

    assert {:ok, decision} =
             Reviews.submit_review(member_scope, %{
               "subject_kind" => "observation",
               "subject_id" => observation.id,
               "classification" => "passed_but_should_have_failed",
               "action" => "contract_revision",
               "rationale" => "A prohibited response shape passed the current contract."
             })

    assert decision.subject_kind == :observation
    assert decision.capture_observation_id == observation.id
    assert decision.capture_evaluation_id == evaluation.id
    assert decision.result_alert_id == nil
    assert decision.reviewer_user_id == member.user.id
  end

  test "foreign evidence stays hidden", %{fixture: fixture, scope: scope} do
    %{alert: alert, run: run} = failed_run(fixture, scope)
    other_scope = workspace_scope_fixture()

    assert {:error, :not_found} =
             Reviews.submit_review(other_scope, %{
               subject_kind: :alert,
               subject_id: alert.id,
               classification: :confirmed_regression
             })

    assert {:error, :not_found} = Reviews.list_run_reviews(other_scope, run.id)
  end

  test "database rejects decision updates and deletes", %{fixture: fixture, scope: scope} do
    %{alert: alert} = failed_run(fixture, scope)

    assert {:ok, decision} =
             Reviews.submit_review(scope, %{
               subject_kind: :alert,
               subject_id: alert.id,
               classification: :confirmed_regression
             })

    assert_raise Postgrex.Error, ~r/review decisions are append-only/, fn ->
      decision
      |> Ecto.Changeset.change(classification: :acceptable_variation)
      |> Repo.update!()
    end
  end

  defp failed_run(fixture, scope) do
    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    :ok = perform_job(ObservationWorker, job.args)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    %{alert: alert, run: Repo.get!(SilentRegression.Captures.CaptureRun, run.id)}
  end

  defp passing_run(fixture, scope) do
    replace_secret(fixture.credential.id, "sk-test-output-approved")
    {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    :ok = perform_job(ObservationWorker, job.args)

    Repo.get!(SilentRegression.Captures.CaptureRun, run.id)
    |> Repo.preload(observations: [evaluations: :rule_results])
    |> then(&%{run: &1})
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
