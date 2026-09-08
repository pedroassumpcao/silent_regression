defmodule Mix.Tasks.DriftSpike.Control do
  @shortdoc "Captures controls or calibrates frozen drift thresholds"

  @moduledoc """
  Captures provenance-compatible same-model controls and separately calibrates
  immutable per-case lexical thresholds.

  Inspect a live control plan first. For the frozen four-case baseline, the
  default `n=20` plus one model-access check requires at most 81 calls:

      mix drift_spike.control \
        --baseline results/drift_spike/BASELINE.json \
        --provider openai \
        --model gpt-5.6-luna \
        --max-output-tokens 512 \
        --max-calls 81 \
        --seed 20260907 \
        --dry-run

  Remove `--dry-run` only after approving that exact plan. This writes a
  control run artifact and reports its uncalibrated energy distance and
  Benjamini-Hochberg-adjusted p-value for each case.

  After capturing one or more independent controls, build a separate frozen
  threshold artifact without provider calls:

      mix drift_spike.control \
        --calibrate \
        --baseline results/drift_spike/BASELINE.json \
        --control results/drift_spike/CONTROL-1.json \
        --seed 20260907 \
        --dry-run

  Repeat `--control` to pool additional compatible controls. Remove
  `--dry-run` to persist the displayed calibration. Later held-out controls can
  pass `--calibration CALIBRATION.json`; a source control used to construct the
  calibration is rejected as leakage.
  """

  use Mix.Task

  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.Calibrator
  alias SilentRegression.Spike.Control
  alias SilentRegression.Spike.Providers.Anthropic
  alias SilentRegression.Spike.Providers.OpenAI
  alias SilentRegression.Spike.Storage

  @switches [
    baseline: :string,
    control: :keep,
    calibration: :string,
    calibrate: :boolean,
    provider: :string,
    model: :string,
    samples: :integer,
    max_calls: :integer,
    max_retries: :integer,
    concurrency: :integer,
    max_output_tokens: :integer,
    seed: :integer,
    permutations: :integer,
    iterations: :integer,
    quantile: :float,
    alpha: :float,
    label: :string,
    output: :string,
    dry_run: :boolean,
    help: :boolean
  ]

  @capture_only [
    :calibration,
    :concurrency,
    :label,
    :max_calls,
    :max_output_tokens,
    :max_retries,
    :model,
    :permutations,
    :provider,
    :samples
  ]
  @calibration_only [:alpha, :control, :iterations, :quantile]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, remaining, invalid} ->
        cond do
          Keyword.get(options, :help, false) ->
            Mix.shell().info(@moduledoc)

          remaining != [] or invalid != [] ->
            Mix.raise("Invalid control arguments: #{inspect(remaining ++ invalid)}")

          Keyword.get(options, :calibrate, false) ->
            run_calibration(options)

          true ->
            run_capture(options)
        end
    end
  end

  defp run_capture(options) do
    reject_options!(options, @calibration_only, "capture")

    baseline_path = required_string!(options, :baseline)
    provider_name = required_string!(options, :provider)
    model = required_string!(options, :model)
    max_output_tokens = required_integer!(options, :max_output_tokens)
    max_calls = required_integer!(options, :max_calls)
    seed = required_integer!(options, :seed)
    provider = provider!(provider_name)
    baseline = read_run!(baseline_path, "baseline")
    calibration = read_optional_calibration!(options)

    control_options =
      [
        model: model,
        samples_per_case: Keyword.get(options, :samples, 20),
        max_calls: max_calls,
        max_retries: Keyword.get(options, :max_retries, 0),
        max_concurrency: Keyword.get(options, :concurrency, 3),
        seed: seed,
        permutations: Keyword.get(options, :permutations, 999),
        dry_run: Keyword.get(options, :dry_run, false),
        provider_options: [max_output_tokens: max_output_tokens]
      ]
      |> put_optional(:calibration, calibration)
      |> put_optional_from(:label, options)
      |> put_optional_from_as(:output_path, :output, options)

    case Control.run(baseline, provider, control_options) do
      {:ok, %{"status" => "dry_run", "plan" => plan}} -> print_capture_plan(plan)
      {:ok, %{"status" => "completed"} = result} -> print_capture_result(result)
      {:error, error} -> Mix.raise(format_error(error, "Control capture failed"))
    end
  end

  defp run_calibration(options) do
    reject_options!(options, @capture_only, "calibration")

    baseline_path = required_string!(options, :baseline)
    control_paths = Keyword.get_values(options, :control)
    seed = required_integer!(options, :seed)

    if control_paths == [] do
      Mix.raise("At least one --control artifact is required with --calibrate")
    end

    if Enum.uniq(control_paths) != control_paths do
      Mix.raise("--control artifact paths must be unique")
    end

    baseline = read_run!(baseline_path, "baseline")
    controls = Enum.map(control_paths, &read_run!(&1, "control"))

    calibration_options =
      [
        seed: seed,
        iterations: Keyword.get(options, :iterations, 200),
        quantile: Keyword.get(options, :quantile, 0.95),
        adjusted_p_alpha: Keyword.get(options, :alpha, 0.05)
      ]

    case Calibrator.build(baseline, controls, calibration_options) do
      {:ok, calibration} ->
        output_path =
          Keyword.get(
            options,
            :output,
            Path.join("results/drift_spike", "#{calibration.calibration_id}.json")
          )

        if Keyword.get(options, :dry_run, false) do
          print_calibration(calibration, output_path, true)
        else
          case CalibrationStorage.write(output_path, calibration) do
            :ok -> print_calibration(calibration, output_path, false)
            {:error, error} -> Mix.raise(format_error(error, "Calibration write failed"))
          end
        end

      {:error, error} ->
        Mix.raise(format_error(error, "Calibration failed"))
    end
  end

  defp reject_options!(options, forbidden, mode) do
    present = Enum.filter(forbidden, &Keyword.has_key?(options, &1))

    if present != [] do
      switches = present |> Enum.map(&"--#{switch_name(&1)}") |> Enum.join(", ")
      Mix.raise("#{switches} cannot be used in #{mode} mode")
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

  defp read_optional_calibration!(options) do
    case Keyword.fetch(options, :calibration) do
      {:ok, path} ->
        case CalibrationStorage.read(path) do
          {:ok, calibration} -> calibration
          {:error, error} -> Mix.raise(format_error(error, "Could not read calibration artifact"))
        end

      :error ->
        nil
    end
  end

  defp put_optional(options, _name, nil), do: options
  defp put_optional(options, name, value), do: Keyword.put(options, name, value)

  defp put_optional_from(target, name, source),
    do: put_optional_from_as(target, name, name, source)

  defp put_optional_from_as(target, target_name, source_name, source) do
    case Keyword.fetch(source, source_name) do
      {:ok, value} -> Keyword.put(target, target_name, value)
      :error -> target
    end
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

  defp provider!("openai"), do: OpenAI
  defp provider!("anthropic"), do: Anthropic

  defp provider!(provider) do
    Mix.raise("Unsupported provider #{inspect(provider)}; expected openai or anthropic")
  end

  defp print_capture_plan(plan) do
    Mix.shell().info("Drift spike control (dry run)")
    Mix.shell().info("Baseline: #{plan["baseline_run_id"]}")
    Mix.shell().info("Run ID: #{plan["run_id"]}")
    Mix.shell().info("Label: #{plan["label"]}")
    Mix.shell().info("Provider: #{plan["provider"]}")
    Mix.shell().info("Model: #{plan["model"]}")
    Mix.shell().info("Cases (#{plan["case_count"]}):")

    Enum.each(plan["cases"], fn case_summary ->
      Mix.shell().info(
        "  - #{case_summary["id"]} (v#{case_summary["version"]}, #{case_summary["fingerprint"]})"
      )
    end)

    Mix.shell().info("Samples per case: #{plan["samples_per_case"]}")
    Mix.shell().info("Planned samples: #{plan["planned_samples"]}")
    Mix.shell().info("Model availability calls: #{plan["availability_calls"]}")
    Mix.shell().info("Initial generation calls: #{plan["generation_calls"]}")
    Mix.shell().info("Retry calls reserved: #{plan["retry_calls_reserved"]}")
    Mix.shell().info("Maximum provider calls: #{plan["maximum_calls"]}")
    Mix.shell().info("Approved --max-calls cap: #{plan["max_calls"]}")
    Mix.shell().info("Concurrency: #{plan["max_concurrency"]}")
    Mix.shell().info("Comparison seed: #{plan["comparison_seed"]}")
    Mix.shell().info("Permutations per case: #{plan["permutations"]}")
    Mix.shell().info("Calibration: #{plan["calibration_id"] || "none (report only)"}")
    Mix.shell().info("Artifact destination: #{plan["artifact_path"]}")
    Mix.shell().info("Request configuration:")

    plan["request_config"]
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.each(fn {key, value} -> Mix.shell().info("  #{key}: #{inspect(value)}") end)

    Mix.shell().info("No provider requests were made and no artifact was written.")
  end

  defp print_capture_result(result) do
    totals = result["totals"]
    comparison = result["comparison"]

    Mix.shell().info("Drift spike control captured")
    Mix.shell().info("Artifact: #{result["artifact_path"]}")

    Mix.shell().info(
      "Samples: #{totals["successful_samples"]} successful, #{totals["failed_samples"]} failed"
    )

    Mix.shell().info(
      "Completions: #{totals["completed_samples"]} complete, " <>
        "#{totals["incomplete_samples"]} incomplete, " <>
        "#{totals["unknown_completion_samples"]} unknown"
    )

    Mix.shell().info(
      "Quality: #{totals["quality_passed_samples"]} passed, " <>
        "#{totals["quality_failed_samples"]} failed"
    )

    Mix.shell().info(
      "Provider calls: #{totals["actual_calls"]} actual (#{totals["maximum_calls"]} maximum)"
    )

    Mix.shell().info("Successful-sample latency: #{totals["latency_ms"]} ms total")

    Mix.shell().info(
      "Usage: #{totals["input_tokens"]} input tokens, #{totals["output_tokens"]} output tokens"
    )

    Mix.shell().info("Comparison to baseline #{comparison["baseline_run_id"]}:")

    Enum.each(comparison["by_case"], fn case_result ->
      Mix.shell().info("  - #{case_result["case_id"]}")
      Mix.shell().info("    energy distance: #{format_number(case_result["energy_distance"])}")

      Mix.shell().info(
        "    within baseline/control: " <>
          "#{format_number(case_result["within_baseline_mean"])}/" <>
          "#{format_number(case_result["within_candidate_mean"])}"
      )

      Mix.shell().info("    cross mean: #{format_number(case_result["cross_mean"])}")
      Mix.shell().info("    raw p: #{format_number(case_result["p_value"])}")
      Mix.shell().info("    adjusted p: #{format_number(case_result["adjusted_p_value"])}")
      Mix.shell().info("    quality rates: #{format_rate_change(case_result["quality"])}")

      Mix.shell().info(
        "    deterministic rates: #{format_rate_change(case_result["deterministic"])}"
      )

      Mix.shell().info("    threshold: #{format_number(case_result["threshold"])}")
      Mix.shell().info("    outcome: #{case_result["outcome"]}")
    end)
  end

  defp print_calibration(calibration, output_path, dry_run?) do
    heading =
      if dry_run?, do: "Drift spike calibration (dry run)", else: "Drift spike calibration frozen"

    Mix.shell().info(heading)
    Mix.shell().info("Calibration ID: #{calibration.calibration_id}")
    Mix.shell().info("Baseline: #{calibration.baseline_run_id}")
    Mix.shell().info("Controls (#{length(calibration.control_run_ids)}):")
    Enum.each(calibration.control_run_ids, &Mix.shell().info("  - #{&1}"))
    Mix.shell().info("Seed: #{calibration.settings["seed"]}")
    Mix.shell().info("Iterations per case: #{calibration.settings["iterations"]}")
    Mix.shell().info("Quantile: #{format_number(calibration.settings["quantile"])}")

    Mix.shell().info(
      "Adjusted-p alpha: #{format_number(calibration.settings["adjusted_p_alpha"])}"
    )

    Mix.shell().info("Artifact destination: #{output_path}")
    Mix.shell().info("Per-case thresholds:")

    Enum.each(calibration.thresholds, fn threshold ->
      Mix.shell().info(
        "  - #{threshold["case_id"]}: #{format_number(threshold["threshold"])} " <>
          "(null exceedance rate #{format_number(threshold["empirical_exceedance_rate"])})"
      )
    end)

    if dry_run? do
      Mix.shell().info("No provider requests were made and no artifact was written.")
    else
      Mix.shell().info("No provider requests were made; the calibration artifact is immutable.")
    end
  end

  defp format_number(nil), do: "n/a"
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: :erlang.float_to_binary(value, decimals: 6)

  defp format_rate_change(rate_change) do
    "baseline #{format_number(rate_change["baseline_rate"])}, " <>
      "control #{format_number(rate_change["candidate_rate"])}, " <>
      "change #{format_number(rate_change["change"])}"
  end

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
