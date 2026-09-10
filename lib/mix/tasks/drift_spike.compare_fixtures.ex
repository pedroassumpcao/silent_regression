defmodule Mix.Tasks.DriftSpike.CompareFixtures do
  @shortdoc "Compares approved semantic fixtures with frozen drift artifacts"

  @moduledoc """
  Evaluates every human-approved fixture batch against a frozen baseline and
  calibration using one independent held-out control as the batch template.
  This task makes zero provider calls.

      mix drift_spike.compare_fixtures \
        --baseline results/drift_spike/BASELINE.json \
        --calibration results/drift_spike/CALIBRATION.json \
        --control results/drift_spike/HELDOUT-CONTROL.json \
        --seed 20260907 \
        --permutations 999

  The approved fixture directory is selected automatically. `--fixtures` may
  be supplied for clarity, but candidate or arbitrary directories are refused
  for official reports. Use `--dry-run` to calculate and print the complete
  result without persisting it.
  """

  use Mix.Task

  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.FixtureComparison
  alias SilentRegression.Spike.FixtureComparisonStorage
  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.Spike.Storage

  @switches [
    baseline: :string,
    calibration: :string,
    control: :string,
    fixtures: :string,
    seed: :integer,
    permutations: :integer,
    deterministic_drop: :float,
    output: :string,
    dry_run: :boolean,
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
            Mix.raise("Invalid fixture comparison arguments: #{inspect(remaining ++ invalid)}")

          true ->
            run_comparison(options)
        end
    end
  end

  defp run_comparison(options) do
    baseline_path = required_string!(options, :baseline)
    calibration_path = required_string!(options, :calibration)
    control_path = required_string!(options, :control)
    seed = required_integer!(options, :seed)
    fixture_root = Keyword.get(options, :fixtures, FixtureSet.official_root())

    baseline = read_run!(baseline_path, "baseline")
    control = read_run!(control_path, "control")
    calibration = read_calibration!(calibration_path)
    fixture_set = load_fixtures!(fixture_root)

    comparison_options = [
      seed: seed,
      permutations: Keyword.get(options, :permutations, 999),
      deterministic_drop_threshold: Keyword.get(options, :deterministic_drop, 0.0)
    ]

    case FixtureComparison.run(baseline, calibration, control, fixture_set, comparison_options) do
      {:ok, report} ->
        output_path =
          Keyword.get(
            options,
            :output,
            Path.join("results/drift_spike", "#{report["comparison_id"]}.json")
          )

        if Keyword.get(options, :dry_run, false) do
          print_report(report, output_path, true)
        else
          case FixtureComparisonStorage.write(output_path, report) do
            :ok -> print_report(report, output_path, false)
            {:error, error} -> Mix.raise(format_error(error, "Fixture comparison write failed"))
          end
        end

      {:error, error} ->
        Mix.raise(format_error(error, "Fixture comparison failed"))
    end
  end

  defp read_run!(path, expected_condition) do
    case Storage.read(path) do
      {:ok, run} when run.condition == expected_condition ->
        run

      {:ok, run} ->
        Mix.raise(
          "Expected #{expected_condition} artifact at #{path}, got condition #{inspect(run.condition)}"
        )

      {:error, error} ->
        Mix.raise(format_error(error, "Could not read #{expected_condition} artifact"))
    end
  end

  defp read_calibration!(path) do
    case CalibrationStorage.read(path) do
      {:ok, calibration} -> calibration
      {:error, error} -> Mix.raise(format_error(error, "Could not read calibration artifact"))
    end
  end

  defp load_fixtures!(path) do
    case FixtureSet.load(path) do
      {:ok, fixture_set} -> fixture_set
      {:error, error} -> Mix.raise(format_error(error, "Could not load approved fixtures"))
    end
  end

  defp print_report(report, output_path, dry_run?) do
    heading =
      if dry_run?,
        do: "Drift spike fixture comparison (dry run)",
        else: "Drift spike fixture comparison captured"

    Mix.shell().info(heading)
    Mix.shell().info("Artifact: #{output_path}")
    Mix.shell().info("Baseline: #{report["baseline_run_id"]}")
    Mix.shell().info("Calibration: #{report["calibration_id"]}")
    Mix.shell().info("Held-out control: #{report["control_run_id"]}")
    Mix.shell().info("Provider/model: #{report["provider"]}/#{report["requested_model"]}")
    Mix.shell().info("Approved manifest: #{get_in(report, ["fixture_set", "manifest_path"])}")
    Mix.shell().info("Manifest SHA-256: #{get_in(report, ["fixture_set", "manifest_sha256"])}")
    Mix.shell().info("Provider calls: 0")
    Mix.shell().info("Held-out control reference:")
    print_case_results(get_in(report, ["reference_control", "comparison", "by_case"]))

    Enum.each(report["batches"], fn batch ->
      Mix.shell().info(
        "Batch #{batch["batch_id"]} " <>
          "(#{batch["intended_label"]}, seeded rate #{format_number(batch["expected_regression_rate"])})"
      )

      print_case_results(batch["comparison"]["by_case"])
    end)

    print_mixed_sensitivity(report["summary"]["mixed_sensitivity"])

    harmless = report["summary"]["harmless_rewording"]
    regressions = report["summary"]["seeded_regressions"]

    Mix.shell().info(
      "Harmless drift reviews: #{harmless["drift_review_count"]}/#{harmless["case_comparisons"]} " <>
        "(#{format_number(harmless["drift_review_rate"])})"
    )

    Mix.shell().info(
      "Seeded regression signals: #{regressions["any_signal_count"]}/" <>
        "#{regressions["case_comparisons"]} (#{format_number(regressions["any_signal_rate"])})"
    )

    gate = report["summary"]["decision_gate"]
    Mix.shell().info("Decision gate: #{gate["status"]}")
    Mix.shell().info("  #{gate["reason"]}")

    if dry_run? do
      Mix.shell().info("No provider requests were made and no artifact was written.")
    else
      Mix.shell().info("No provider requests were made; the fixture comparison is reproducible.")
    end
  end

  defp print_case_results(results) do
    Enum.each(results, fn result ->
      deterministic = result["deterministic"]

      Mix.shell().info("  - #{result["case_id"]}")

      Mix.shell().info(
        "    deterministic: #{result["deterministic_outcome"]} " <>
          "(#{format_number(deterministic["baseline_rate"])} -> " <>
          "#{format_number(deterministic["candidate_rate"])})"
      )

      Mix.shell().info(
        "    drift: #{result["drift_outcome"]} " <>
          "(energy #{format_number(result["energy_distance"])}, " <>
          "adjusted p #{format_number(result["adjusted_p_value"])}, " <>
          "threshold #{format_number(result["threshold"])})"
      )

      Mix.shell().info("    combined: #{result["alert_outcome"]}")
    end)
  end

  defp print_mixed_sensitivity(results) do
    Mix.shell().info("Mixed-regression sensitivity:")

    Enum.each(results, fn result ->
      Mix.shell().info(
        "  - #{format_number(result["expected_regression_rate"])}: " <>
          "#{result["any_signal_count"]}/#{result["case_comparisons"]} any signal, " <>
          "#{result["deterministic_regression_count"]} deterministic, " <>
          "#{result["drift_review_count"]} drift review"
      )
    end)
  end

  defp required_string!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      {:ok, _value} -> Mix.raise("--#{switch_name(name)} must be a non-empty string")
      :error -> Mix.raise("--#{switch_name(name)} is required")
    end
  end

  defp required_integer!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) -> value
      {:ok, _value} -> Mix.raise("--#{switch_name(name)} must be an integer")
      :error -> Mix.raise("--#{switch_name(name)} is required")
    end
  end

  defp switch_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp format_number(nil), do: "n/a"
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: :erlang.float_to_binary(value, decimals: 6)

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
