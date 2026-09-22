defmodule SilentRegression.WorkspaceLifecycleTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorsFixtures
  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Captures
  alias SilentRegression.MonitorOperations
  alias SilentRegression.MonitorOperations.AuthenticationRecovery
  alias SilentRegression.MonitorSetups
  alias SilentRegression.MonitorSetups.Setup
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.Notifications
  alias SilentRegression.Notifications.Delivery
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.Incident
  alias SilentRegression.WorkspaceLifecycle
  alias SilentRegression.WorkspaceLifecycle.DeletionReceipt
  alias SilentRegression.WorkspaceLifecycle.Workers.PurgeWorker
  alias SilentRegression.Workspaces.Workspace

  describe "close_workspace/4" do
    test "owners close immediately with a 30-day recovery window and execution disabled" do
      scope = workspace_scope_fixture()
      credential = provider_credential_fixture(scope)
      monitor = monitor_fixture(scope)

      monitor
      |> Ecto.Changeset.change(state: :active, state_changed_at: ~U[2026-09-16 10:00:00Z])
      |> Repo.update!()

      at = ~U[2026-09-16 12:00:00Z]

      assert {:error, :confirmation_mismatch} =
               WorkspaceLifecycle.close_workspace(
                 scope,
                 :closure_retention,
                 "wrong-slug",
                 at: at
               )

      assert {:ok, %{workspace: closed, receipt: receipt}} =
               WorkspaceLifecycle.close_workspace(
                 scope,
                 :closure_retention,
                 scope.workspace.slug,
                 at: at
               )

      assert closed.status == :closed
      assert closed.closed_at == at
      assert closed.deletion_requested_at == nil
      assert closed.purge_after == DateTime.add(at, 30, :day)
      assert receipt.request_type == :closure_retention
      assert byte_size(receipt.workspace_fingerprint) == 32

      assert Repo.get!(ProviderCredential, credential.id).status == :revoked

      assert %{state: :paused, pause_reason: :workspace_closed, next_run_at: nil} =
               Repo.get!(Monitor, monitor.id)

      assert {:error, :not_found} =
               SilentRegression.Workspaces.scope_for_slug(
                 Scope.for_user(scope.user),
                 scope.workspace.slug
               )
    end

    test "members cannot close a workspace" do
      owner_scope = workspace_scope_fixture()
      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      assert {:error, :owner_required} =
               WorkspaceLifecycle.close_workspace(
                 member_scope,
                 :closure_retention,
                 member.workspace.slug
               )

      assert Repo.get!(Workspace, owner_scope.workspace.id).status == :active
    end
  end

  describe "operator recovery and purge" do
    test "ordinary closure can be reopened before its deadline without re-enabling credentials" do
      scope = workspace_scope_fixture()
      credential = provider_credential_fixture(scope)
      at = ~U[2026-09-16 12:00:00Z]

      assert {:ok, %{receipt: receipt}} =
               WorkspaceLifecycle.close_workspace(
                 scope,
                 :closure_retention,
                 scope.workspace.slug,
                 at: at
               )

      assert {:ok, reopened} =
               WorkspaceLifecycle.operator_reopen(
                 scope.workspace.slug,
                 scope.user.email,
                 at: DateTime.add(at, 1, :day)
               )

      assert reopened.status == :active
      assert reopened.closed_at == nil
      assert Repo.get!(ProviderCredential, credential.id).status == :revoked
      assert Repo.get!(DeletionReceipt, receipt.id).status == :cancelled
    end

    test "explicit deletion is irreversible and purge removes customer data but keeps a receipt" do
      scope = workspace_scope_fixture()
      fixture = approved_baseline_fixture(scope)
      {:ok, guided_draft} = SilentRegression.GuidedSetups.create(scope)

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

      assert {:ok, successor_setup} =
               MonitorSetups.start_successor(scope, fixture.monitor.id)

      replace_secret(fixture.credential.id, "sk-test-output-maybe")
      _failed_run = complete_manual_run!(scope, fixture.monitor.id)
      [incident] = Repo.all(Incident)

      replace_secret(fixture.credential.id, "sk-test-output-approved")
      clean_run = complete_manual_run!(scope, fixture.monitor.id)
      assert Repo.get!(Incident, incident.id).recovery_capture_run_id == clean_run.id

      recovery = authentication_recovery_fixture(scope, fixture)
      at = ~U[2026-09-16 12:00:00Z]

      assert :ok =
               Notifications.prepare_capacity_wait!(
                 fixture.monitor,
                 :workspace_run_limit,
                 at,
                 DateTime.add(at, 12, :hour)
               )

      delivery =
        scope
        |> Notifications.list_deliveries()
        |> Enum.find(&(&1.kind == :coverage_interrupted))

      assert Repo.get!(AuthenticationRecovery, recovery.id)
      assert Repo.get!(Delivery, delivery.id)

      assert {:ok, %{receipt: receipt}} =
               WorkspaceLifecycle.close_workspace(
                 scope,
                 :explicit_request,
                 scope.workspace.slug,
                 at: at
               )

      assert {:error, :deletion_is_irreversible} =
               WorkspaceLifecycle.operator_reopen(
                 scope.workspace.slug,
                 scope.user.email,
                 at: at
               )

      assert {:ok, %{request_id: request_id}} =
               WorkspaceLifecycle.operator_purge_due_workspace(scope.workspace.slug, at: at)

      assert request_id == receipt.request_id
      assert Repo.get(Workspace, scope.workspace.id) == nil
      assert Repo.get(User, scope.user.id) == nil
      assert Repo.get(Monitor, fixture.monitor.id) == nil
      assert Repo.get(ProviderCredential, fixture.credential.id) == nil
      assert Repo.get(AuthenticationRecovery, recovery.id) == nil
      assert Repo.get(Incident, incident.id) == nil
      assert Repo.get(Delivery, delivery.id) == nil
      assert Repo.get(Setup, successor_setup.id) == nil
      assert Repo.get(SilentRegression.GuidedSetups.Draft, guided_draft.id) == nil

      assert %{status: :completed, completed_at: ^at} =
               Repo.get!(DeletionReceipt, receipt.id)
    end

    test "purge preserves an identity that still belongs to another workspace" do
      first_scope = workspace_scope_fixture()

      second =
        accepted_workspace_fixture(%{
          workspace_slug: unique_workspace_slug(),
          email: first_scope.user.email
        })

      at = ~U[2026-09-16 12:00:00Z]

      assert {:ok, _closure} =
               WorkspaceLifecycle.close_workspace(
                 first_scope,
                 :explicit_request,
                 first_scope.workspace.slug,
                 at: at
               )

      assert {:ok, _receipt} =
               WorkspaceLifecycle.operator_purge_due_workspace(first_scope.workspace.slug, at: at)

      assert Repo.get!(User, first_scope.user.id).id == second.user.id
      assert Repo.get!(Workspace, second.workspace.id).status == :active
    end

    test "periodic maintenance purges only due workspaces in bounded batches" do
      due_scope = workspace_scope_fixture()
      retained_scope = workspace_scope_fixture()
      at = ~U[2026-09-20 12:00:00Z]

      assert {:ok, _closure} =
               WorkspaceLifecycle.close_workspace(
                 due_scope,
                 :explicit_request,
                 due_scope.workspace.slug,
                 at: at
               )

      assert {:ok, _closure} =
               WorkspaceLifecycle.close_workspace(
                 retained_scope,
                 :closure_retention,
                 retained_scope.workspace.slug,
                 at: at
               )

      assert {:ok, %{selected: 1, purged: 1, failed: 0}} =
               WorkspaceLifecycle.purge_due_workspaces(at: at, limit: 1)

      assert Repo.get(Workspace, due_scope.workspace.id) == nil
      assert Repo.get!(Workspace, retained_scope.workspace.id).status == :closed
      assert :ok = perform_job(PurgeWorker, %{})
    end
  end

  defp authentication_recovery_fixture(scope, fixture) do
    assert {:ok, _monitor} =
             MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    for _attempt <- 1..2 do
      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert {:ok, run} = Captures.get_run(scope, run.id)
      [observation] = run.observations
      assert :ok = Captures.execute_observation(run.id, observation.id)
    end

    assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()
    replace_secret(fixture.credential.id, "sk-test-recovery-valid")

    assert {:ok, %{recovery: recovery}} =
             MonitorOperations.authorize_authentication_recovery(scope, fixture.monitor.id)

    recovery
  end

  defp replace_secret(credential_id, secret) do
    ProviderCredential
    |> Repo.get!(credential_id)
    |> Ecto.Changeset.change(secret: secret)
    |> Repo.update!()
  end

  defp complete_manual_run!(scope, monitor_id) do
    assert {:ok, run} = MonitorOperations.run_now(scope, monitor_id)
    assert {:ok, loaded} = Captures.get_run(scope, run.id)

    Enum.each(loaded.observations, fn observation ->
      assert :ok = Captures.execute_observation(run.id, observation.id)
    end)

    assert {:ok, %{status: :synchronized}} = RunResults.sync_run(run.id)

    Repo.get!(SilentRegression.Captures.CaptureRun, run.id)
  end
end
