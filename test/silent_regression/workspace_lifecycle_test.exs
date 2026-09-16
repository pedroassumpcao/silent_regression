defmodule SilentRegression.WorkspaceLifecycleTest do
  use SilentRegression.DataCase, async: false

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorsFixtures
  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.WorkspaceLifecycle
  alias SilentRegression.WorkspaceLifecycle.DeletionReceipt
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
      at = ~U[2026-09-16 12:00:00Z]

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
  end
end
