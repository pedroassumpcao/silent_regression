defmodule SilentRegression.NotificationsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import Ecto.Query
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures
  import Swoosh.TestAssertions

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.Notifications
  alias SilentRegression.Notifications.Delivery
  alias SilentRegression.Notifications.Workers.AlertEmailWorker
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.Alert

  test "preferences are personal to a member inside one workspace" do
    owner_scope = workspace_scope_fixture()
    member = invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

    assert Notifications.get_preference(member_scope).actionable_alert_email_enabled

    assert {:ok, disabled} =
             Notifications.update_preference(member_scope, %{
               "actionable_alert_email_enabled" => false
             })

    refute disabled.actionable_alert_email_enabled
    assert Notifications.get_preference(owner_scope).actionable_alert_email_enabled
  end

  test "alert synchronization creates one ID-only delivery and sends content-free email once" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    plaintext = "sk-test-authentication-error"
    replace_secret(fixture.credential.id, plaintext)

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [capture_job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, capture_job.args)

    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    assert alert.notification_state == :pending

    assert [delivery] = Notifications.list_deliveries(scope)
    assert delivery.status == :pending
    assert delivery.recipient_user_id == scope.user.id

    assert [email_job] = all_enqueued(worker: AlertEmailWorker)
    assert email_job.args == %{"delivery_id" => delivery.id}
    refute inspect(email_job.args) =~ plaintext

    assert {:ok, %{status: :synchronized}} = RunResults.sync_run(run.id)
    assert [_delivery] = Notifications.list_deliveries(scope)
    assert [_email_job] = all_enqueued(worker: AlertEmailWorker)

    assert :ok = perform_job(AlertEmailWorker, email_job.args)

    sent = Repo.get!(Delivery, delivery.id)
    assert sent.status == :sent
    assert sent.attempts == 1
    assert Repo.get!(Alert, alert.id).notification_state == :sent

    assert_email_sent(fn email ->
      assert email.to == [{"", scope.user.email}]
      assert email.subject == "Critical alert for #{fixture.monitor.name}"
      assert email.text_body =~ "Operational anomaly"

      assert email.text_body =~
               "/app/#{scope.workspace.slug}/monitors/#{fixture.monitor.id}/runs/#{run.id}"

      refute email.text_body =~ plaintext
      refute email.text_body =~ alert.explanation
      true
    end)

    assert :ok = perform_job(AlertEmailWorker, email_job.args)
    refute_email_sent()
    assert Repo.get!(Delivery, delivery.id).attempts == 1
  end

  test "a preference disabled after enqueue skips delivery without sending" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [capture_job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, capture_job.args)
    [delivery] = Notifications.list_deliveries(scope)

    assert {:ok, _preference} =
             Notifications.update_preference(scope, %{actionable_alert_email_enabled: false})

    assert :ok = perform_job(AlertEmailWorker, %{"delivery_id" => delivery.id})

    skipped = Repo.get!(Delivery, delivery.id)
    assert skipped.status == :skipped
    assert skipped.outcome_reason == :preference_disabled
    assert Repo.get!(Alert, delivery.result_alert_id).notification_state == :not_configured
    refute_email_sent()
  end

  test "an alert remains unconfigured when every recipient opted out before creation" do
    scope = workspace_scope_fixture()

    assert {:ok, _preference} =
             Notifications.update_preference(scope, %{actionable_alert_email_enabled: false})

    fixture = operational_monitor_fixture(scope)
    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [capture_job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, capture_job.args)

    assert Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id).notification_state ==
             :not_configured

    assert [] = Notifications.list_deliveries(scope)
    assert [] = all_enqueued(worker: AlertEmailWorker)
    refute_email_sent()
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
