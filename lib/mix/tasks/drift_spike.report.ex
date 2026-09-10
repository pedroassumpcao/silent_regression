defmodule Mix.Tasks.DriftSpike.Report do
  @shortdoc "Builds the consolidated drift spike feasibility summary"

  @moduledoc """
  Builds a deterministic Markdown summary from explicit immutable artifacts and
  compatible run files in the results directory. This task makes zero provider
  calls.

      mix drift_spike.report \
        --results results/drift_spike \
        --baseline results/drift_spike/BASELINE.json \
        --calibration results/drift_spike/CALIBRATION.json \
        --fixture-comparison results/drift_spike/FIXTURE-COMPARISON.json \
        --output results/drift_spike/SUMMARY.md

  Until a human explicitly selects a conclusion, the report records
  `PENDING_HUMAN_VERDICT`. An approved verdict can be supplied with `--verdict`:

  * `PROMISING_FOR_DETERMINISTIC_AND_DRIFT_TRIAGE`
  * `PROMISING_FOR_DETERMINISTIC_ONLY`
  * `NEEDS_A_SEMANTIC_LAYER`
  * `NOT_VIABLE_AS_DESIGNED`

  Existing output files are never overwritten.
  """

  use Mix.Task

  alias SilentRegression.Spike.Report

  @switches [
    results: :string,
    baseline: :string,
    calibration: :string,
    fixture_comparison: :string,
    output: :string,
    verdict: :string,
    help: :boolean
  ]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, remaining, invalid} ->
        cond do
          Keyword.get(options, :help, false) ->
            Mix.shell().info(@moduledoc)

          remaining != [] or invalid != [] ->
            Mix.raise("Invalid report arguments: #{inspect(remaining ++ invalid)}")

          true ->
            build_report(options)
        end
    end
  end

  defp build_report(options) do
    output_path = required_string!(options, :output)

    paths = %{
      "results_directory" => required_string!(options, :results),
      "baseline_path" => required_string!(options, :baseline),
      "calibration_path" => required_string!(options, :calibration),
      "fixture_comparison_path" => required_string!(options, :fixture_comparison)
    }

    report_options =
      case Keyword.fetch(options, :verdict) do
        {:ok, verdict} -> [verdict: verdict]
        :error -> []
      end

    with {:ok, report} <- Report.build(paths, report_options),
         :ok <- Report.write(output_path, report["markdown"]) do
      print_report(report, output_path)
    else
      {:error, error} -> Mix.raise(format_error(error, "Consolidated report failed"))
    end
  end

  defp print_report(report, output_path) do
    scan = report["artifact_scan"]
    totals = report["operational_totals"]

    Mix.shell().info("Drift spike feasibility summary captured")
    Mix.shell().info("Artifact: #{output_path}")
    Mix.shell().info("Human verdict: #{report["verdict"]}")
    Mix.shell().info("Provider/model: #{report["provider"]}/#{report["requested_model"]}")
    Mix.shell().info("Included live runs: #{scan["included_run_count"]}")
    Mix.shell().info("Included historical provider request attempts: #{totals["actual_calls"]}")
    Mix.shell().info("Provider calls made by this report: 0")

    Enum.each(scan["warnings"], fn warning ->
      Mix.shell().info(
        "Warning [#{warning["type"]}] #{Path.basename(warning["path"])}: " <>
          warning["message"]
      )
    end)

    Mix.shell().info("Artifact warnings: #{scan["warning_count"]}")
  end

  defp required_string!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      {:ok, _value} -> Mix.raise("--#{switch_name(name)} must be a non-empty string")
      :error -> Mix.raise("--#{switch_name(name)} is required")
    end
  end

  defp switch_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
