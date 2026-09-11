defmodule Mix.Tasks.DriftSpike.SemanticDecisionReport do
  @shortdoc "Builds the Task E semantic-layer decision report"

  @moduledoc """
  Builds a zero-call comparison report from the pinned deterministic, lexical,
  and cheap-semantic spike artifacts.

      mix drift_spike.semantic_decision_report

  Without `--decision`, the immutable draft records
  `PENDING_HUMAN_DECISION`. After explicit human approval, pass one of:

  * `CHEAP_LAYER_PROMISING`
  * `DETERMINISTIC_ONLY_WEDGE`
  * `EVALUATE_MODEL_BASED_SEMANTICS`
  * `STOP_TECHNICAL_VALIDATION`

  Use `--dry-run` to render and validate without writing. `--manifest` and
  `--output` exist for reproducibility tests and alternate artifact locations.
  Existing output files are never overwritten.
  """

  use Mix.Task

  alias SilentRegression.Spike.SemanticLayer.DecisionReport

  @default_manifest "priv/drift_spike/semantic_layer/decision-report-inputs-v1.json"
  @draft_output "results/drift_spike/semantic-layer/semantic-layer-decision-report-draft-v1.md"
  @final_output "results/drift_spike/semantic-layer/semantic-layer-decision-report-final-v1.md"
  @switches [
    decision: :string,
    manifest: :string,
    output: :string,
    dry_run: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, [], []} ->
        if Keyword.get(options, :help, false),
          do: Mix.shell().info(@moduledoc),
          else: build(options)

      {_options, remaining, invalid} ->
        Mix.raise("Invalid semantic decision report arguments: #{inspect(remaining ++ invalid)}")
    end
  end

  defp build(options) do
    manifest = Keyword.get(options, :manifest, @default_manifest)
    dry_run? = Keyword.get(options, :dry_run, false)
    report_options = decision_option(options)

    with {:ok, report} <- DecisionReport.build(manifest, report_options),
         output <- output_path(options, report),
         :ok <- maybe_write(output, report["markdown"], dry_run?) do
      print_report(report, output, dry_run?)
    else
      {:error, error} -> Mix.raise(format_error(error))
    end
  end

  defp decision_option(options) do
    case Keyword.fetch(options, :decision) do
      {:ok, decision} -> [decision: decision]
      :error -> []
    end
  end

  defp output_path(options, report) do
    Keyword.get_lazy(options, :output, fn ->
      if report["human_decision"] == DecisionReport.pending_decision(),
        do: @draft_output,
        else: @final_output
    end)
  end

  defp maybe_write(_output, _markdown, true), do: :ok
  defp maybe_write(output, markdown, false), do: DecisionReport.write(output, markdown)

  defp print_report(report, output, dry_run?) do
    heading =
      if dry_run?, do: "Task E decision report (dry run)", else: "Task E decision report captured"

    deterministic = report["deterministic_contracts"]
    lexical = report["lexical_distribution"]
    semantic = report["cheap_semantic"]

    Mix.shell().info(heading)
    Mix.shell().info("Artifact: #{output}")
    Mix.shell().info("Recommendation: #{report["recommendation"]}")
    Mix.shell().info("Human decision: #{report["human_decision"]}")

    Mix.shell().info(
      "Deterministic agreement: #{deterministic["matched_expectation_count"]}/#{deterministic["fixture_count"]}"
    )

    Mix.shell().info(
      "Lexical false reviews: #{lexical["false_review_count"]}/#{lexical["harmless_case_comparison_count"]}"
    )

    Mix.shell().info(
      "Cheap-semantic held-out false reviews: #{semantic["heldout_harmless_review_count"]}/#{semantic["heldout_harmless_comparison_count"]}"
    )

    Mix.shell().info("Provider calls made by this report: 0")

    if dry_run?, do: Mix.shell().info("No artifact was written.")
  end

  defp format_error(error) do
    type = Map.get(error, :type, Map.get(error, "type", :unknown_error))
    message = Map.get(error, :message, Map.get(error, "message", "Decision report failed"))
    details = Map.get(error, :details, Map.get(error, "details", error))
    "#{message} (#{type}): #{inspect(details)}"
  end
end
