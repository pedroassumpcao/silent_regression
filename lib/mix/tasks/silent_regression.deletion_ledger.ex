defmodule Mix.Tasks.SilentRegression.DeletionLedger do
  @shortdoc "Exports a signed content-free deletion ledger"

  @moduledoc """
  Exports the authoritative pending and completed deletion receipts for an
  isolated restore reconciliation:

      mix silent_regression.deletion_ledger --output /secure/path/deletions.json

  The output contains keyed workspace fingerprints and no customer content or
  direct workspace identifiers. Store it separately from database backups.
  """

  use Mix.Task

  alias SilentRegression.WorkspaceLifecycle.DeletionLedger

  @switches [output: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    output = parse_output!(args)
    ledger = DeletionLedger.export()
    File.write!(output, Jason.encode_to_iodata!(ledger, pretty: true))

    Mix.shell().info("Deletion ledger exported")
    Mix.shell().info("Entries: #{length(ledger["entries"])}")
    Mix.shell().info("Ledger SHA256: #{DeletionLedger.digest(ledger)}")
  end

  defp parse_output!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] or opts[:output] in [nil, ""] do
      Mix.raise(
        "Provide exactly one --output path. Run `mix help silent_regression.deletion_ledger`."
      )
    end

    opts[:output]
  end
end
