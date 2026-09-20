defmodule Mix.Tasks.SilentRegression.ReconcileDeletions do
  @shortdoc "Previews or reapplies signed deletions after an isolated restore"

  @moduledoc """
  Preview a signed ledger against an isolated restored database:

      mix silent_regression.reconcile_deletions --ledger /secure/path/deletions.json

  Execution is irreversible. Re-run with `--execute` and the exact SHA256 shown
  by preview only while the restored system is isolated from traffic:

      mix silent_regression.reconcile_deletions \
        --ledger /secure/path/deletions.json \
        --execute \
        --confirm-ledger-sha EXACT_SHA256
  """

  use Mix.Task

  alias SilentRegression.WorkspaceLifecycle
  alias SilentRegression.WorkspaceLifecycle.DeletionLedger

  @switches [ledger: :string, execute: :boolean, confirm_ledger_sha: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse!(args)
    ledger = read_ledger!(opts[:ledger])
    digest = DeletionLedger.digest(ledger)
    validate_execution_confirmation!(opts, digest)

    case WorkspaceLifecycle.reconcile_deletion_ledger(ledger, execute: opts[:execute] || false) do
      {:ok, summary} -> print_summary(summary, digest, opts[:execute] || false)
      {:error, reason} -> Mix.raise("Deletion reconciliation refused: #{inspect(reason)}")
    end
  end

  defp parse!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] or opts[:ledger] in [nil, ""] do
      Mix.raise(
        "Provide exactly one --ledger path. Run `mix help silent_regression.reconcile_deletions`."
      )
    end

    opts
  end

  defp read_ledger!(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, ledger} when is_map(ledger) <- Jason.decode(contents) do
      ledger
    else
      _other -> Mix.raise("The deletion ledger is missing or is not valid JSON.")
    end
  end

  defp validate_execution_confirmation!(opts, digest) do
    if opts[:execute] and opts[:confirm_ledger_sha] != digest do
      Mix.raise("--confirm-ledger-sha must exactly match #{digest}")
    end
  end

  defp print_summary(summary, digest, execute?) do
    Mix.shell().info(
      if(execute?,
        do: "Deletion reconciliation completed",
        else: "Deletion reconciliation preview"
      )
    )

    Mix.shell().info("Ledger SHA256: #{digest}")
    Mix.shell().info("Ledger entries: #{summary.ledger_entries}")
    Mix.shell().info("Actionable entries: #{summary.actionable}")
    Mix.shell().info("Already absent: #{summary.absent}")
    Mix.shell().info("Would reapply: #{summary.would_reapply}")
    Mix.shell().info("Reapplied: #{summary.reapplied}")
    Mix.shell().info("Failed: #{summary.failed}")

    unless execute? do
      Mix.shell().info(
        "No data changed. Use --execute with the exact ledger SHA256 after review."
      )
    end
  end
end
