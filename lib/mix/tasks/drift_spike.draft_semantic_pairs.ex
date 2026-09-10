defmodule Mix.Tasks.DriftSpike.DraftSemanticPairs do
  @shortdoc "Drafts diversity-matched semantic fixture pairs from two controls"

  @moduledoc """
  Creates candidate-only tuning and held-out paired fixture artifacts from two
  compatible pilot controls. The task makes zero provider calls and never
  approves fixtures.

      mix drift_spike.draft_semantic_pairs --tuning TUNING-CONTROL.json --heldout HELDOUT-CONTROL.json --output semantic-candidates

  Use `--dry-run` to validate sources and print counts without writing files.
  Existing artifacts are never overwritten.
  """

  use Mix.Task

  alias SilentRegression.Spike.SemanticLayer.PairedFixtureDraft
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Statistics
  alias SilentRegression.Spike.Storage

  @minimum_diversity_ratio 0.75

  @switches [
    tuning: :string,
    heldout: :string,
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
            Mix.raise("Invalid semantic-pair arguments: #{inspect(remaining ++ invalid)}")

          true ->
            draft(options)
        end
    end
  end

  defp draft(options) do
    tuning_path = required_string!(options, :tuning)
    heldout_path = required_string!(options, :heldout)
    output_directory = required_string!(options, :output)
    dry_run? = Keyword.get(options, :dry_run, false)

    tuning = read_control!(tuning_path)
    heldout = read_control!(heldout_path)
    ensure_distinct_runs!(tuning.run_id, heldout.run_id)

    created_at = DateTime.utc_now() |> DateTime.truncate(:second)
    git_revision = git_revision!()

    tuning_set =
      build!(tuning, tuning_path, "tuning", created_at, git_revision)

    heldout_set =
      build!(heldout, heldout_path, "heldout", created_at, git_revision)

    ensure_disjoint_outputs!(tuning_set, heldout_set)
    tuning_diversity = diversity!(tuning_set, tuning)
    heldout_diversity = diversity!(heldout_set, heldout)

    tuning_output = Path.join(output_directory, "tuning-pairs.json")
    heldout_output = Path.join(output_directory, "heldout-pairs.json")

    if dry_run? do
      print_summary(
        tuning_set,
        heldout_set,
        tuning_diversity,
        heldout_diversity,
        tuning_output,
        heldout_output,
        true
      )
    else
      ensure_destinations_absent!([tuning_output, heldout_output])
      write!(tuning_output, tuning_set)
      write!(heldout_output, heldout_set)

      print_summary(
        tuning_set,
        heldout_set,
        tuning_diversity,
        heldout_diversity,
        tuning_output,
        heldout_output,
        false
      )
    end
  end

  defp read_control!(path) do
    case Storage.read(path) do
      {:ok, run} when run.condition == "control" ->
        run

      {:ok, run} ->
        Mix.raise("Expected a control artifact at #{path}, got #{inspect(run.condition)}")

      {:error, error} ->
        Mix.raise(format_error(error, "Could not read control artifact"))
    end
  end

  defp build!(control, path, split, created_at, git_revision) do
    case PairedFixtureDraft.build(control, file_sha256!(path), split,
           clock: fn -> created_at end,
           git_revision: git_revision
         ) do
      {:ok, fixture_set} -> fixture_set
      {:error, error} -> Mix.raise(format_error(error, "Could not draft #{split} fixtures"))
    end
  end

  defp ensure_distinct_runs!(run_id, run_id) do
    Mix.raise("Tuning and held-out artifacts must be different control runs")
  end

  defp ensure_distinct_runs!(_tuning_run_id, _heldout_run_id), do: :ok

  defp ensure_disjoint_outputs!(tuning, heldout) do
    tuning_outputs = MapSet.new(tuning.fixtures, & &1["output_text"])
    heldout_outputs = MapSet.new(heldout.fixtures, & &1["output_text"])

    if MapSet.disjoint?(tuning_outputs, heldout_outputs),
      do: :ok,
      else: Mix.raise("Tuning and held-out candidate outputs must be disjoint")
  end

  defp diversity!(fixture_set, control) do
    parent_outputs =
      control.samples
      |> Enum.filter(&(&1["case_id"] == fixture_set.source_control["case_id"]))
      |> Enum.sort_by(& &1["sample_index"])
      |> Enum.map(&get_in(&1, ["response", "output_text"]))

    labels =
      Enum.map(~w(meaning_preserving style_only subtle_regression), fn label ->
        outputs =
          fixture_set.fixtures
          |> Enum.filter(&(&1["label"] == label))
          |> Enum.sort_by(& &1["parent_sample_index"])
          |> Enum.map(& &1["output_text"])

        case Statistics.energy_distance(parent_outputs, outputs) do
          {:ok, metrics} ->
            parent_mean = metrics["within_reference_mean"]
            candidate_mean = metrics["within_candidate_mean"]

            if parent_mean <= 0 do
              Mix.raise("Parent outputs need positive within-batch lexical diversity")
            end

            ratio = candidate_mean / parent_mean

            if ratio >= @minimum_diversity_ratio do
              %{
                "label" => label,
                "parent_mean" => parent_mean,
                "candidate_mean" => candidate_mean,
                "ratio" => ratio
              }
            else
              Mix.raise(
                "#{label} within-batch diversity ratio #{format_number(ratio)} is below " <>
                  "the #{@minimum_diversity_ratio}x parent safeguard"
              )
            end

          {:error, error} ->
            Mix.raise("Could not measure #{label} candidate diversity: #{inspect(error)}")
        end
      end)

    %{"parent_mean" => hd(labels)["parent_mean"], "labels" => labels}
  end

  defp ensure_destinations_absent!(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> :ok
      path -> Mix.raise("Refusing to overwrite existing semantic fixture artifact #{path}")
    end
  end

  defp write!(path, fixture_set) do
    case SemanticStorage.write(path, fixture_set) do
      :ok -> :ok
      {:error, error} -> Mix.raise(format_error(error, "Could not write semantic fixture set"))
    end
  end

  defp print_summary(
         tuning,
         heldout,
         tuning_diversity,
         heldout_diversity,
         tuning_path,
         heldout_path,
         dry_run?
       ) do
    heading =
      if dry_run?,
        do: "Semantic paired fixtures (dry run)",
        else: "Semantic paired fixture candidates captured"

    Mix.shell().info(heading)
    print_set("Tuning", tuning, tuning_diversity, tuning_path)
    print_set("Held-out", heldout, heldout_diversity, heldout_path)
    Mix.shell().info("Total parent observations: 40")
    Mix.shell().info("Total candidate judgments requiring review: 120")
    Mix.shell().info("Cross-split candidate output overlap: 0")
    Mix.shell().info("Provider calls: 0")

    if dry_run? do
      Mix.shell().info("No artifacts were written.")
    else
      Mix.shell().info("All fixtures remain candidates pending explicit human approval.")
    end
  end

  defp print_set(label, fixture_set, diversity, path) do
    Mix.shell().info("#{label} artifact: #{path}")
    Mix.shell().info("  source: #{fixture_set.source_control["run_id"]}")
    Mix.shell().info("  parents: 20")
    Mix.shell().info("  candidates: #{length(fixture_set.fixtures)}")
    Mix.shell().info("  parent within-Jaccard mean: #{format_number(diversity["parent_mean"])}")

    Enum.each(fixture_set.duplicate_counts, fn counts ->
      label_diversity = Enum.find(diversity["labels"], &(&1["label"] == counts["label"]))

      Mix.shell().info(
        "  #{counts["label"]}: #{counts["unique_output_count"]}/" <>
          "#{counts["sample_count"]} unique outputs; within-Jaccard " <>
          "#{format_number(label_diversity["candidate_mean"])} " <>
          "(#{format_number(label_diversity["ratio"])}x parent)"
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

  defp switch_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")
  defp format_number(value), do: :erlang.float_to_binary(value / 1, decimals: 6)

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
