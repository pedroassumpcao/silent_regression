defmodule Mix.Tasks.DriftSpike.PromoteSemanticPairs do
  @shortdoc "Promotes fully reviewed semantic-pair candidates"

  @moduledoc """
  Verifies the completed review log and exact candidate hashes, then creates
  new immutable approved tuning and held-out fixture artifacts.

      mix drift_spike.promote_semantic_pairs \\
        --tuning candidates/tuning-pairs.json \\
        --heldout candidates/heldout-pairs.json \\
        --review-log REVIEW_LOG.md \\
        --reviewer product_owner \\
        --output approved

  Use `--dry-run` to validate the complete promotion without writing files.
  The task makes zero provider calls and never overwrites an artifact.
  """

  use Mix.Task

  alias SilentRegression.Spike.SemanticLayer.PairedFixturePromotion
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage

  @approval_phrases [
    "Approve tuning parents 1–5",
    "Approve tuning parents 6–10",
    "Approve tuning parents 11–15",
    "Approve tuning parents 16–20",
    "Approve held-out parents 1–5",
    "Approve held-out parents 6–10",
    "Approve held-out parents 11–15",
    "Approve held-out parents 16–20"
  ]

  @completion_markers [
    "- Approved: 120/120 judgments — complete",
    "- Tuning: 60/60 approved — complete",
    "- Held-out: 60/60 approved — complete",
    "- Corrections requested: 0"
  ]

  @switches [
    tuning: :string,
    heldout: :string,
    review_log: :string,
    reviewer: :string,
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
            Mix.raise("Invalid semantic-promotion arguments: #{inspect(remaining ++ invalid)}")

          true ->
            promote(options)
        end
    end
  end

  defp promote(options) do
    tuning_path = required_string!(options, :tuning)
    heldout_path = required_string!(options, :heldout)
    review_log_path = required_string!(options, :review_log)
    reviewer = required_string!(options, :reviewer)
    output_directory = required_string!(options, :output)
    dry_run? = Keyword.get(options, :dry_run, false)

    tuning = read_candidate!(tuning_path, "tuning")
    heldout = read_candidate!(heldout_path, "heldout")
    ensure_distinct_candidates!(tuning, heldout)
    tuning_sha256 = file_sha256!(tuning_path)
    heldout_sha256 = file_sha256!(heldout_path)
    verify_review_log!(review_log_path, tuning_sha256, heldout_sha256)

    reviewed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    git_revision = git_revision!()
    approved_tuning = promote!(tuning, reviewer, reviewed_at, git_revision)
    approved_heldout = promote!(heldout, reviewer, reviewed_at, git_revision)

    tuning_output = Path.join(output_directory, "tuning-pairs.json")
    heldout_output = Path.join(output_directory, "heldout-pairs.json")

    if dry_run? do
      print_summary(
        approved_tuning,
        approved_heldout,
        tuning_sha256,
        heldout_sha256,
        tuning_output,
        heldout_output,
        reviewer,
        true
      )
    else
      ensure_destinations_absent!([tuning_output, heldout_output])
      write!(tuning_output, approved_tuning)
      write!(heldout_output, approved_heldout)

      print_summary(
        approved_tuning,
        approved_heldout,
        tuning_sha256,
        heldout_sha256,
        tuning_output,
        heldout_output,
        reviewer,
        false
      )
    end
  end

  defp read_candidate!(path, split) do
    case SemanticStorage.read(path) do
      {:ok, fixture_set} ->
        ensure_candidate_split!(fixture_set, split)
        fixture_set

      {:error, error} ->
        Mix.raise(format_error(error, "Could not read #{split} candidate fixture set"))
    end
  end

  defp ensure_candidate_split!(fixture_set, split) do
    fixture_splits = fixture_set.fixtures |> Enum.map(& &1["split"]) |> Enum.uniq()
    label_counts = Enum.frequencies_by(fixture_set.fixtures, & &1["label"])

    expected_label_counts = %{
      "meaning_preserving" => 20,
      "style_only" => 20,
      "subtle_regression" => 20
    }

    parent_count =
      fixture_set.fixtures
      |> Enum.map(& &1["parent_observation_id"])
      |> MapSet.new()
      |> MapSet.size()

    cond do
      fixture_set.status != "candidate" ->
        Mix.raise("Expected a candidate fixture set for #{split}")

      fixture_splits != [split] ->
        Mix.raise("Expected only #{split} fixtures, got #{inspect(fixture_splits)}")

      length(fixture_set.fixtures) != 60 or parent_count != 20 or
          label_counts != expected_label_counts ->
        Mix.raise("Expected exactly 20 complete three-judgment parents for #{split}")

      true ->
        :ok
    end
  end

  defp ensure_distinct_candidates!(tuning, heldout) do
    tuning_parent_ids = MapSet.new(tuning.fixtures, & &1["parent_observation_id"])
    heldout_parent_ids = MapSet.new(heldout.fixtures, & &1["parent_observation_id"])
    tuning_fixture_ids = MapSet.new(tuning.fixtures, & &1["fixture_id"])
    heldout_fixture_ids = MapSet.new(heldout.fixtures, & &1["fixture_id"])
    tuning_outputs = MapSet.new(tuning.fixtures, & &1["output_text"])
    heldout_outputs = MapSet.new(heldout.fixtures, & &1["output_text"])

    cond do
      tuning.source_control["run_id"] == heldout.source_control["run_id"] ->
        Mix.raise("Tuning and held-out candidates must reference distinct controls")

      not MapSet.disjoint?(tuning_parent_ids, heldout_parent_ids) ->
        Mix.raise("Tuning and held-out parent observations must be disjoint")

      not MapSet.disjoint?(tuning_fixture_ids, heldout_fixture_ids) ->
        Mix.raise("Tuning and held-out fixture IDs must be disjoint")

      not MapSet.disjoint?(tuning_outputs, heldout_outputs) ->
        Mix.raise("Tuning and held-out candidate outputs must be disjoint")

      true ->
        :ok
    end
  end

  defp verify_review_log!(path, tuning_sha256, heldout_sha256) do
    contents = read_file!(path, "review log")

    required_evidence =
      @completion_markers ++
        @approval_phrases ++
        ["`#{tuning_sha256}`", "`#{heldout_sha256}`"]

    case Enum.reject(required_evidence, &String.contains?(contents, &1)) do
      [] ->
        :ok

      missing ->
        Mix.raise(
          "Review log is incomplete or does not match the candidates: #{inspect(missing)}"
        )
    end
  end

  defp promote!(candidate, reviewer, reviewed_at, git_revision) do
    case PairedFixturePromotion.promote(candidate, reviewer,
           clock: fn -> reviewed_at end,
           git_revision: git_revision
         ) do
      {:ok, fixture_set} -> fixture_set
      {:error, error} -> Mix.raise(format_error(error, "Could not promote fixture set"))
    end
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
      {:error, error} -> Mix.raise(format_error(error, "Could not write approved fixture set"))
    end
  end

  defp print_summary(
         tuning,
         heldout,
         tuning_sha256,
         heldout_sha256,
         tuning_path,
         heldout_path,
         reviewer,
         dry_run?
       ) do
    heading =
      if dry_run?,
        do: "Semantic paired fixture promotion (dry run)",
        else: "Semantic paired fixtures promoted"

    Mix.shell().info(heading)
    print_set("Tuning", tuning, tuning_sha256, tuning_path)
    print_set("Held-out", heldout, heldout_sha256, heldout_path)
    Mix.shell().info("Reviewer: #{reviewer}")
    Mix.shell().info("Approved judgments: 120/120")
    Mix.shell().info("Provider calls: 0")

    if dry_run?,
      do: Mix.shell().info("No artifacts were written."),
      else: Mix.shell().info("Candidate artifacts were not changed.")
  end

  defp print_set(label, fixture_set, candidate_sha256, path) do
    Mix.shell().info("#{label} approved artifact: #{path}")
    Mix.shell().info("  fixture set: #{fixture_set.fixture_set_id}")
    Mix.shell().info("  candidate SHA-256: #{candidate_sha256}")
    Mix.shell().info("  approved fixtures: #{length(fixture_set.fixtures)}")
  end

  defp required_string!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      {:ok, _value} -> Mix.raise("--#{switch_name(name)} must be a non-empty string")
      :error -> Mix.raise("--#{switch_name(name)} is required")
    end
  end

  defp file_sha256!(path), do: path |> read_file!("artifact") |> sha256()

  defp read_file!(path, label) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> Mix.raise("Could not read #{label} #{path}: #{inspect(reason)}")
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

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  defp switch_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
