defmodule SilentRegression.RunResultsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import Ecto.Query
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
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

  test "members acknowledge while only owners resolve the forward-only lifecycle", %{
    fixture: fixture,
    scope: owner_scope
  } do
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(owner_scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)

    assert {:error, :acknowledgement_required} =
             RunResults.resolve_alert(owner_scope, alert.id)

    member = invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
    acknowledged_at = ~U[2026-09-16 19:00:00.000000Z]

    assert {:ok, acknowledged} =
             RunResults.acknowledge_alert(member_scope, alert.id, at: acknowledged_at)

    assert acknowledged.status == :acknowledged
    assert acknowledged.acknowledged_by_user_id == member.user.id
    assert acknowledged.acknowledged_at == acknowledged_at
    assert {:error, :owner_required} = RunResults.resolve_alert(member_scope, alert.id)

    resolved_at = ~U[2026-09-16 19:05:00.000000Z]
    assert {:ok, resolved} = RunResults.resolve_alert(owner_scope, alert.id, at: resolved_at)
    assert resolved.status == :resolved
    assert resolved.resolved_by_user_id == owner_scope.user.id
    assert resolved.resolved_at == resolved_at

    assert {:ok, repeated} = RunResults.resolve_alert(owner_scope, alert.id)
    assert repeated.resolved_at == resolved_at

    actions = owner_scope |> Audit.list_workspace_events() |> Enum.map(& &1.action)
    assert "alert.acknowledged" in actions
    assert "alert.resolved" in actions

    assert_raise Postgrex.Error, ~r/invalid result alert lifecycle transition/, fn ->
      resolved
      |> Ecto.Changeset.change(
        status: :acknowledged,
        resolved_at: nil,
        resolved_by_user_id: nil
      )
      |> Repo.update!()
    end
  end

  test "alert access remains inside workspace scope", %{fixture: fixture, scope: scope} do
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    other_scope = workspace_scope_fixture()

    assert {:error, :not_found} = RunResults.get_alert(other_scope, alert.id)
    assert {:error, :not_found} = RunResults.acknowledge_alert(other_scope, alert.id)
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
