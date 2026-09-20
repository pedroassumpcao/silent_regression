defmodule SilentRegression.WorkspaceLifecycle.DeletionLedgerTest do
  use SilentRegression.DataCase, async: false

  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Repo
  alias SilentRegression.WorkspaceLifecycle
  alias SilentRegression.WorkspaceLifecycle.{DeletionLedger, DeletionReceipt}
  alias SilentRegression.Workspaces.Workspace

  test "exports and verifies only signed content-free receipt evidence" do
    scope = workspace_scope_fixture()
    at = ~U[2026-09-20 12:00:00Z]

    assert {:ok, %{receipt: receipt}} =
             WorkspaceLifecycle.close_workspace(
               scope,
               :explicit_request,
               scope.workspace.slug,
               at: at
             )

    ledger = DeletionLedger.export(at: at)

    assert %{
             "schema_version" => 1,
             "exported_at" => "2026-09-20T12:00:00Z",
             "entries" => [entry],
             "signature" => signature
           } = ledger

    assert is_binary(signature)
    assert entry["request_id"] == receipt.request_id
    refute inspect(ledger) =~ scope.workspace.slug
    refute inspect(ledger) =~ scope.user.email

    assert {:ok, [verified]} = DeletionLedger.verify(ledger)
    assert verified.request_id == receipt.request_id
    assert verified.workspace_fingerprint == receipt.workspace_fingerprint

    tampered = put_in(ledger, ["entries", Access.at(0), "status"], "completed")
    assert {:error, :invalid_ledger_signature} = DeletionLedger.verify(tampered)
  end

  test "previews and reapplies an authoritative deletion after a restored backup" do
    scope = workspace_scope_fixture()
    workspace_id = scope.workspace.id
    at = ~U[2026-09-20 12:00:00Z]

    assert {:ok, %{receipt: receipt}} =
             WorkspaceLifecycle.close_workspace(
               scope,
               :explicit_request,
               scope.workspace.slug,
               at: at
             )

    ledger = DeletionLedger.export(at: at)

    # Simulate an isolated restore from a backup taken before the deletion request.
    Repo.delete!(receipt)

    Workspace
    |> Repo.get!(workspace_id)
    |> Ecto.Changeset.change(
      status: :active,
      closed_at: nil,
      deletion_requested_at: nil,
      purge_after: nil,
      closed_by_user_id: nil
    )
    |> Repo.update!()

    assert {:ok, %{would_reapply: 1, reapplied: 0, failed: 0}} =
             WorkspaceLifecycle.reconcile_deletion_ledger(ledger, at: at)

    assert Repo.get!(Workspace, workspace_id).status == :active

    assert {:ok, %{would_reapply: 0, reapplied: 1, failed: 0}} =
             WorkspaceLifecycle.reconcile_deletion_ledger(ledger, at: at, execute: true)

    assert Repo.get(Workspace, workspace_id) == nil

    assert %{status: :completed, request_id: request_id} =
             Repo.get_by!(DeletionReceipt, request_id: receipt.request_id)

    assert request_id == receipt.request_id

    assert {:ok, %{absent: 1, reapplied: 0, failed: 0}} =
             WorkspaceLifecycle.reconcile_deletion_ledger(ledger, at: at, execute: true)
  end

  test "keeps future retention closures out of reconciliation" do
    scope = workspace_scope_fixture()
    at = ~U[2026-09-20 12:00:00Z]

    assert {:ok, _closure} =
             WorkspaceLifecycle.close_workspace(
               scope,
               :closure_retention,
               scope.workspace.slug,
               at: at
             )

    ledger = DeletionLedger.export(at: at)

    assert {:ok, %{actionable: 0, would_reapply: 0, reapplied: 0}} =
             WorkspaceLifecycle.reconcile_deletion_ledger(ledger, at: at, execute: true)

    assert Repo.get!(Workspace, scope.workspace.id).status == :closed
  end
end
