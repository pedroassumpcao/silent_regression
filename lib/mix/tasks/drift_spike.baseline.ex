defmodule Mix.Tasks.DriftSpike.Baseline do
  @shortdoc "Plans or captures a drift-spike baseline"

  @moduledoc """
  Captures a versioned baseline pool, its deterministic results, and its
  within-run lexical variability.

  First inspect the call-free plan. With all four cases, the default `n=30`,
  and no retries, the one model-access check brings the cap to 121 requests:

      mix drift_spike.baseline \
        --provider openai \
        --model gpt-5.6-luna \
        --max-output-tokens 256 \
        --max-calls 121 \
        --dry-run

  After approving that exact plan, remove `--dry-run` to initiate the live
  baseline. Omit `--case` to use every frozen case, or repeat it to select
  cases. Live runs check account access to the exact model immediately before
  generation and never substitute another model.
  """

  use Mix.Task

  alias SilentRegression.Spike.Baseline
  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Providers.Anthropic
  alias SilentRegression.Spike.Providers.OpenAI

  @switches [
    provider: :string,
    model: :string,
    case: :keep,
    samples: :integer,
    max_calls: :integer,
    max_retries: :integer,
    concurrency: :integer,
    max_output_tokens: :integer,
    label: :string,
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

          remaining == [] and invalid == [] ->
            run_baseline(options)

          true ->
            Mix.raise("Invalid baseline arguments: #{inspect(remaining ++ invalid)}")
        end
    end
  end

  defp run_baseline(options) do
    provider_name = required_string!(options, :provider)
    model = required_string!(options, :model)
    max_output_tokens = required_integer!(options, :max_output_tokens)
    max_calls = required_integer!(options, :max_calls)
    provider = provider!(provider_name)
    cases = cases!(Keyword.get_values(options, :case))

    baseline_options =
      [
        model: model,
        samples_per_case: Keyword.get(options, :samples, 30),
        max_calls: max_calls,
        max_retries: Keyword.get(options, :max_retries, 0),
        max_concurrency: Keyword.get(options, :concurrency, 3),
        dry_run: Keyword.get(options, :dry_run, false),
        provider_options: [max_output_tokens: max_output_tokens]
      ]
      |> put_optional(:label, options)
      |> put_optional_as(:output_path, :output, options)

    case Baseline.run(cases, provider, baseline_options) do
      {:ok, %{"status" => "dry_run", "plan" => plan}} ->
        print_plan(plan)

      {:ok, %{"status" => "completed"} = result} ->
        print_result(result)

      {:error, error} ->
        Mix.raise(format_error(error))
    end
  end

  defp put_optional(target, name, source), do: put_optional_as(target, name, name, source)

  defp put_optional_as(target, target_name, source_name, source) do
    case Keyword.fetch(source, source_name) do
      {:ok, value} -> Keyword.put(target, target_name, value)
      :error -> target
    end
  end

  defp required_string!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          Mix.raise("--#{switch_name(name)} must be a non-empty string")
        else
          value
        end

      {:ok, _value} ->
        Mix.raise("--#{switch_name(name)} must be a string")

      :error ->
        Mix.raise("--#{switch_name(name)} is required")
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

  defp cases!([]), do: CaseSet.all()

  defp cases!(case_ids) do
    if Enum.uniq(case_ids) != case_ids do
      Mix.raise("--case values must be unique")
    end

    Enum.map(case_ids, fn case_id ->
      case CaseSet.fetch(case_id) do
        {:ok, case_definition} -> case_definition
        :error -> Mix.raise("Unknown spike case #{inspect(case_id)}")
      end
    end)
  end

  defp print_plan(plan) do
    Mix.shell().info("Drift spike baseline (dry run)")
    Mix.shell().info("Run ID: #{plan["run_id"]}")
    Mix.shell().info("Label: #{plan["label"]}")
    Mix.shell().info("Provider: #{plan["provider"]}")
    Mix.shell().info("Model: #{plan["model"]}")
    Mix.shell().info("Cases (#{plan["case_count"]}):")

    Enum.each(plan["cases"], fn case_summary ->
      Mix.shell().info("  - #{case_summary["id"]} (v#{case_summary["version"]})")
    end)

    Mix.shell().info("Samples per case: #{plan["samples_per_case"]}")
    Mix.shell().info("Planned samples: #{plan["planned_samples"]}")
    Mix.shell().info("Model availability calls: #{plan["availability_calls"]}")
    Mix.shell().info("Initial generation calls: #{plan["generation_calls"]}")
    Mix.shell().info("Retry calls reserved: #{plan["retry_calls_reserved"]}")
    Mix.shell().info("Maximum provider calls: #{plan["maximum_calls"]}")
    Mix.shell().info("Approved --max-calls cap: #{plan["max_calls"]}")
    Mix.shell().info("Concurrency: #{plan["max_concurrency"]}")
    Mix.shell().info("Artifact destination: #{plan["artifact_path"]}")
    Mix.shell().info("Request configuration:")

    plan["request_config"]
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.each(fn {key, value} -> Mix.shell().info("  #{key}: #{inspect(value)}") end)

    credential = plan["credential"]

    if credential["required"] do
      Mix.shell().info("Credential: #{credential["env_var"]} is present")
    end

    Mix.shell().info("No provider requests were made and no artifact was written.")
  end

  defp print_result(result) do
    totals = result["totals"]

    Mix.shell().info("Drift spike baseline captured")
    Mix.shell().info("Artifact: #{result["artifact_path"]}")

    Mix.shell().info(
      "Samples: #{totals["successful_samples"]} successful, #{totals["failed_samples"]} failed"
    )

    Mix.shell().info(
      "Provider calls: #{totals["actual_calls"]} actual (#{totals["maximum_calls"]} maximum)"
    )

    Mix.shell().info("Successful-sample latency: #{totals["latency_ms"]} ms total")

    Mix.shell().info(
      "Usage: #{totals["input_tokens"]} input tokens, #{totals["output_tokens"]} output tokens"
    )

    Mix.shell().info("Per-case characteristics:")

    Enum.each(result["metrics"]["by_case"], fn case_metrics ->
      deterministic = case_metrics["deterministic"]
      within_distance = case_metrics["within_distance"]

      Mix.shell().info("  - #{case_metrics["case_id"]}")

      Mix.shell().info(
        "    samples: #{case_metrics["successful_samples"]} successful, #{case_metrics["failed_samples"]} failed"
      )

      Mix.shell().info(
        "    deterministic sample pass rate: #{format_rate(deterministic["sample_pass_rate"])} " <>
          "(#{deterministic["passed_samples"]}/#{deterministic["evaluated_samples"]})"
      )

      Mix.shell().info(
        "    deterministic check pass rate: #{format_rate(deterministic["check_pass_rate"])} " <>
          "(#{deterministic["passed_checks"]}/#{deterministic["total_checks"]})"
      )

      Mix.shell().info("    within-distance: #{format_distance(within_distance)}")
      Mix.shell().info("    latency: #{format_numeric_summary(case_metrics["latency_ms"], "ms")}")

      usage = case_metrics["usage"]

      Mix.shell().info(
        "    usage: #{usage["input_tokens"]} input, #{usage["output_tokens"]} output tokens"
      )
    end)
  end

  defp format_rate(nil), do: "n/a"
  defp format_rate(value), do: :erlang.float_to_binary(value, decimals: 4)

  defp format_distance(%{"status" => "insufficient_data"} = summary) do
    "insufficient data (#{summary["successful_samples"]}/#{summary["minimum_successful_samples"]} successful samples)"
  end

  defp format_distance(summary) do
    format_numeric_summary(summary, "") <> " across #{summary["pair_count"]} pairs"
  end

  defp format_numeric_summary(%{"status" => "insufficient_data"}, _unit), do: "n/a"

  defp format_numeric_summary(summary, unit) do
    suffix = if unit == "", do: "", else: " #{unit}"

    "mean #{format_number(summary["mean"])}#{suffix}, " <>
      "min #{format_number(summary["minimum"])}#{suffix}, " <>
      "max #{format_number(summary["maximum"])}#{suffix}, " <>
      "sample sd #{format_number(summary["sample_standard_deviation"])}#{suffix}"
  end

  defp format_number(nil), do: "n/a"
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: :erlang.float_to_binary(value, decimals: 4)

  defp format_error(error) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, "Baseline capture failed"))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error), do: "Baseline capture failed: #{inspect(error)}"
end
