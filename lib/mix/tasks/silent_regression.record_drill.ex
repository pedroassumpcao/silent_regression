defmodule Mix.Tasks.SilentRegression.RecordDrill do
  @shortdoc "Records a bounded hosted-pilot operational drill"

  @moduledoc """
  Records one allowlisted drill attestation without free-form notes:

      mix silent_regression.record_drill \
        --kind backup_restore \
        --outcome passed \
        --operator founder@example.com \
        --evidence-ref ops://2026-09-20/restore-1

  Environment and release default to the runtime pilot-readiness configuration.
  """

  use Mix.Task

  alias SilentRegression.PilotReadiness

  @switches [
    kind: :string,
    outcome: :string,
    operator: :string,
    evidence_ref: :string,
    environment: :string,
    release_sha: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse!(args)

    attrs = %{
      kind: opts[:kind],
      outcome: opts[:outcome],
      operator_identifier: opts[:operator],
      evidence_ref: opts[:evidence_ref],
      environment: opts[:environment],
      release_sha: opts[:release_sha]
    }

    case PilotReadiness.record_drill(attrs) do
      {:ok, drill} ->
        Mix.shell().info("Operational drill recorded")
        Mix.shell().info("Kind: #{drill.kind}")
        Mix.shell().info("Outcome: #{drill.outcome}")
        Mix.shell().info("Environment: #{drill.environment}")
        Mix.shell().info("Release: #{drill.release_sha}")
        Mix.shell().info("Expires: #{DateTime.to_iso8601(drill.expires_at)}")

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not record drill: #{inspect(changeset.errors)}")
    end
  end

  defp parse!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    required = [:kind, :outcome, :operator, :evidence_ref]

    if positional != [] or invalid != [] or Enum.any?(required, &(opts[&1] in [nil, ""])) do
      Mix.raise("Required: --kind, --outcome, --operator, and --evidence-ref.")
    end

    opts
  end
end
