defmodule Mix.Tasks.DriftSpike.RescoreSemanticContracts do
  @shortdoc "Rescores approved fixtures with the frozen semantic contracts"

  @moduledoc """
  Rescores the approved Task 10 authoring fixtures and one approved paired
  tuning or held-out fixture set. The task is local, makes zero provider calls,
  and writes a new immutable result without changing fixture artifacts.

      mix drift_spike.rescore_semantic_contracts \\
        --paired APPROVED-PAIRS.json \\
        --output RESULT.json

  Use `--dry-run` to validate and print the complete summary without writing.
  """

  use Mix.Task

  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.Spike.SemanticLayer.ContractRescore
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage

  @switches [paired: :string, output: :string, dry_run: :boolean, help: :boolean]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, remaining, invalid} ->
        cond do
          Keyword.get(options, :help, false) ->
            Mix.shell().info(@moduledoc)

          remaining != [] or invalid != [] ->
            Mix.raise("Invalid semantic-rescore arguments: #{inspect(remaining ++ invalid)}")

          true ->
            rescore(options)
        end
    end
  end

  defp rescore(options) do
    paired_path = required_string!(options, :paired)
    output_path = required_string!(options, :output)
    dry_run? = Keyword.get(options, :dry_run, false)
    authoring = load_authoring!()
    paired = read_paired!(paired_path)
    paired_sha256 = file_sha256!(paired_path)

    result =
      run_rescore!(authoring, paired, paired_sha256, git_revision: git_revision!())

    if dry_run? do
      print_summary(result, output_path, true)
    else
      write!(output_path, result)
      print_summary(result, output_path, false)
    end
  end

  defp load_authoring! do
    case FixtureSet.load() do
      {:ok, fixture_set} -> fixture_set
      {:error, error} -> Mix.raise(format_error(error, "Could not load Task 10 fixtures"))
    end
  end

  defp read_paired!(path) do
    case SemanticStorage.read(path) do
      {:ok, fixture_set} -> fixture_set
      {:error, error} -> Mix.raise(format_error(error, "Could not read paired fixture set"))
    end
  end

  defp run_rescore!(authoring, paired, paired_sha256, options) do
    case ContractRescore.run(authoring, paired, paired_sha256, options) do
      {:ok, result} -> result
      {:error, error} -> Mix.raise(format_error(error, "Could not rescore semantic contracts"))
    end
  end

  defp write!(path, result) do
    case SemanticStorage.write(path, result) do
      :ok -> :ok
      {:error, error} -> Mix.raise(format_error(error, "Could not write semantic rescore"))
    end
  end

  defp print_summary(result, output_path, dry_run?) do
    summary = result.summary
    paired_source = Enum.find(result.sources, &(&1["source_type"] == "paired_fixture_set"))

    heading =
      if dry_run?,
        do: "Semantic contract rescore (dry run)",
        else: "Semantic contract rescore captured"

    Mix.shell().info(heading)
    Mix.shell().info("Artifact: #{output_path}")
    Mix.shell().info("Evaluation: #{result.evaluation_id}")
    Mix.shell().info("Contract set: #{result.contract_set["contract_set_id"]}")
    Mix.shell().info("Contract fingerprint: #{result.contract_set["fingerprint"]}")
    Mix.shell().info("Paired split: #{paired_source["split"]}")

    Mix.shell().info(
      "Matched judgments: #{summary["matched_expectation_count"]}/#{summary["fixture_count"]}"
    )

    Mix.shell().info(
      "Expected-valid passes: #{summary["expected_pass_matched_count"]}/" <>
        "#{summary["expected_pass_count"]}"
    )

    Mix.shell().info(
      "Expected regressions detected: #{summary["expected_fail_matched_count"]}/" <>
        "#{summary["expected_fail_count"]}"
    )

    Enum.each(summary["by_failure_mode"], fn failure_mode ->
      Mix.shell().info(
        "  #{failure_mode["failure_mode"]}: #{failure_mode["detected_count"]}/" <>
          "#{failure_mode["fixture_count"]} detected"
      )
    end)

    Mix.shell().info("Provider calls: #{result.provider_calls}")

    if dry_run?,
      do: Mix.shell().info("No artifact was written."),
      else: Mix.shell().info("Source fixture artifacts were not changed.")
  end

  defp required_string!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      {:ok, _value} -> Mix.raise("--#{name} must be a non-empty string")
      :error -> Mix.raise("--#{name} is required")
    end
  end

  defp file_sha256!(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:error, reason} -> Mix.raise("Could not hash #{path}: #{inspect(reason)}")
    end
  end

  defp git_revision! do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} ->
        String.trim(revision)

      {output, status} ->
        Mix.raise("Could not read git revision (#{status}): #{String.trim(output)}")
    end
  end

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
