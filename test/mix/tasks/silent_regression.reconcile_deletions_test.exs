defmodule Mix.Tasks.SilentRegression.ReconcileDeletionsTest do
  use SilentRegression.DataCase, async: false

  import ExUnit.CaptureIO
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Repo
  alias SilentRegression.WorkspaceLifecycle
  alias SilentRegression.WorkspaceLifecycle.DeletionLedger
  alias SilentRegression.Workspaces.Workspace

  setup do
    Mix.Task.reenable("silent_regression.reconcile_deletions")
    :ok
  end

  test "previews a ledger without requiring the execute flag or changing data" do
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

    # Simulate a backup restored from before the authoritative deletion.
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

    ledger_path =
      Path.join(
        System.tmp_dir!(),
        "silent-regression-ledger-#{System.unique_integer([:positive])}.json"
      )

    File.write!(ledger_path, Jason.encode!(ledger))
    on_exit(fn -> File.rm(ledger_path) end)

    output =
      capture_io(fn ->
        Mix.Tasks.SilentRegression.ReconcileDeletions.run(["--ledger", ledger_path])
      end)

    assert output =~ "Deletion reconciliation preview"
    assert output =~ "Would reapply: 1"
    assert output =~ "Reapplied: 0"
    assert output =~ "No data changed"
    assert Repo.get!(Workspace, workspace_id).status == :active
  end
end
