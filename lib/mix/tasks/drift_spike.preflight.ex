defmodule Mix.Tasks.DriftSpike.Preflight do
  @shortdoc "Prints a call-free drift-spike execution plan"

  @moduledoc """
  Validates and prints a drift-spike provider request plan without making any
  provider calls.

      mix drift_spike.preflight \
        --provider openai \
        --model gpt-5.6-luna \
        --max-output-tokens 256 \
        --samples 1 \
        --max-retries 0 \
        --max-calls 4 \
        --dry-run

  Omit `--case` to plan all frozen cases, or repeat it to select cases:

      --case rag_structured_extract --case rag_answer_with_citations

  The command is always a dry run. The optional `--dry-run` flag makes that
  intent visible in copied commands but never changes the task into a live run.
  """

  use Mix.Task

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Providers.Anthropic
  alias SilentRegression.Spike.Providers.OpenAI
  alias SilentRegression.Spike.Runner

  @switches [
    provider: :string,
    model: :string,
    case: :keep,
    samples: :integer,
    max_calls: :integer,
    max_retries: :integer,
    concurrency: :integer,
    max_output_tokens: :integer,
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
            run_preflight(options)

          true ->
            Mix.raise("Invalid preflight arguments: #{inspect(remaining ++ invalid)}")
        end
    end
  end

  defp run_preflight(options) do
    provider_name = required_string!(options, :provider)
    model = required_string!(options, :model)
    max_output_tokens = required_integer!(options, :max_output_tokens)
    max_calls = required_integer!(options, :max_calls)
    provider = provider!(provider_name)
    cases = cases!(Keyword.get_values(options, :case))

    runner_options = [
      model: model,
      samples_per_case: Keyword.get(options, :samples, 1),
      max_calls: max_calls,
      max_retries: Keyword.get(options, :max_retries, 0),
      max_concurrency: Keyword.get(options, :concurrency, 3),
      dry_run: true,
      provider_options: [max_output_tokens: max_output_tokens]
    ]

    case Runner.run(cases, provider, runner_options) do
      {:ok, %{"status" => "dry_run", "plan" => plan}} ->
        print_plan(plan)

      {:error, error} ->
        Mix.raise(format_error(error))
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
    Mix.shell().info("Drift spike preflight (dry run)")
    Mix.shell().info("Provider: #{plan["provider"]}")
    Mix.shell().info("Model: #{plan["model"]}")
    Mix.shell().info("Cases (#{plan["case_count"]}):")

    Enum.each(plan["cases"], fn case_summary ->
      Mix.shell().info("  - #{case_summary["id"]} (v#{case_summary["version"]})")
    end)

    Mix.shell().info("Samples per case: #{plan["samples_per_case"]}")
    Mix.shell().info("Planned samples: #{plan["planned_samples"]}")
    Mix.shell().info("Initial provider calls: #{plan["planned_calls"]}")
    Mix.shell().info("Retry calls reserved: #{plan["retry_calls_reserved"]}")
    Mix.shell().info("Maximum provider calls: #{plan["maximum_calls"]}")
    Mix.shell().info("Approved --max-calls cap: #{plan["max_calls"]}")
    Mix.shell().info("Concurrency: #{plan["max_concurrency"]}")
    Mix.shell().info("Request configuration:")

    plan["request_config"]
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.each(fn {key, value} -> Mix.shell().info("  #{key}: #{inspect(value)}") end)

    credential = plan["credential"]

    if credential["required"] do
      Mix.shell().info("Credential: #{credential["env_var"]} is present")
    end

    Mix.shell().info("No provider requests were made.")
  end

  defp format_error(error) do
    details = error |> Map.get("details", %{}) |> inspect()
    "#{error["message"]} (#{error["type"]}): #{details}"
  end
end
