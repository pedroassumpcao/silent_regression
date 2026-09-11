defmodule Mix.Tasks.DriftSpike.BenchmarkSemanticHeldout do
  @shortdoc "Evaluates the frozen Task D winner on held-out semantic fixtures"

  @moduledoc """
  Validates the tracked pre-held-out freeze manifest, refits only the selected
  representation from its pinned baseline/control sources, and evaluates the
  approved held-out batches exactly once.

      mix drift_spike.benchmark_semantic_heldout

  The task is local, makes zero provider calls, and refuses a dirty worktree or
  any changed method, calibration, tuning-result, seed, threshold, or fixture
  hash. Use `--dry-run` to calculate without writing the result artifact.
  """

  use Mix.Task

  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfig
  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkFreeze
  alias SilentRegression.Spike.SemanticLayer.Representation
  alias SilentRegression.Spike.SemanticLayer.RepresentationBenchmark
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Storage

  @switches [dry_run: :boolean, help: :boolean]
  @output_path "results/drift_spike/semantic-layer/semantic-benchmark-final-evaluation-v1.json"

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, [], []} ->
        if Keyword.get(options, :help, false),
          do: Mix.shell().info(@moduledoc),
          else: benchmark(Keyword.get(options, :dry_run, false))

      {_options, remaining, invalid} ->
        Mix.raise("Invalid held-out benchmark arguments: #{inspect(remaining ++ invalid)}")
    end
  end

  defp benchmark(dry_run?) do
    ensure_clean_worktree!()
    current_revision = git_revision!()
    freeze = read_freeze!()
    validate_method_revision!(freeze, current_revision)
    validate_tuning_selection!(freeze)
    baseline_source = read_frozen_run!(CheapBenchmarkConfig.baseline())
    control_sources = Enum.map(CheapBenchmarkConfig.fit_controls(), &read_frozen_run!/1)
    bundle = load_selected_bundle!(freeze, baseline_source, control_sources)

    # The held-out file is intentionally opened only after all selection,
    # method, calibration, and null-source checks above have succeeded.
    fixtures = read_heldout_fixtures!(freeze["heldout_fixture_set"])
    settings = freeze["settings"]

    result =
      case RepresentationBenchmark.run(
             baseline_source.run,
             fixtures,
             freeze["heldout_fixture_set"]["artifact_sha256"],
             [bundle],
             evaluation_role: "final_evaluation",
             seeds: settings["seeds"],
             permutations: settings["permutations"],
             adjusted_p_alpha: settings["adjusted_p_alpha"],
             harmless_review_rate_maximum: settings["harmless_review_rate_maximum"],
             subtle_review_rate_minimum: settings["subtle_review_rate_minimum"],
             multiple_comparison_family: settings["multiple_comparison_family"],
             result_id: "semantic-benchmark-final-evaluation-v1",
             git_revision: current_revision
           ) do
        {:ok, result} -> result
        {:error, error} -> Mix.raise(format_error(error, "Held-out benchmark failed"))
      end

    unless dry_run?, do: write!(@output_path, result)
    print_result(result, dry_run?)
  end

  defp read_freeze! do
    case CheapBenchmarkFreeze.load() do
      {:ok, freeze} -> freeze
      {:error, error} -> Mix.raise(format_error(error, "Could not load benchmark freeze"))
    end
  end

  defp validate_method_revision!(freeze, current_revision) do
    ancestor = freeze["method_git_revision"]

    case System.cmd("git", ["merge-base", "--is-ancestor", ancestor, current_revision],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> Mix.raise("Frozen method revision is not an ancestor: #{output}")
    end
  end

  defp validate_tuning_selection!(freeze) do
    reference = freeze["tuning_result"]
    verify_hash!(reference["path"], reference["artifact_sha256"])

    tuning = read_semantic!(reference["path"])
    expected_ids = freeze["selection_policy"]["selected_representation_ids"]

    cond do
      not match?(%BenchmarkResult{}, tuning) ->
        Mix.raise("Frozen tuning reference is not a benchmark result")

      tuning.result_id != reference["result_id"] or tuning.evaluation_role != "method_selection" ->
        Mix.raise("Frozen tuning result identity changed")

      tuning.summary["gate_status"] != "passed" ->
        Mix.raise("Frozen tuning result did not pass its selection gate")

      tuning.summary["selected_representation_ids"] != expected_ids ->
        Mix.raise("Frozen tuning selection changed")

      true ->
        :ok
    end
  end

  defp load_selected_bundle!(freeze, baseline_source, control_sources) do
    representation_reference = freeze["selected_representation"]
    calibration_reference = freeze["calibration"]
    verify_hash!(representation_reference["path"], representation_reference["artifact_sha256"])
    verify_hash!(calibration_reference["path"], calibration_reference["artifact_sha256"])
    spec = read_semantic!(representation_reference["path"])
    calibration = read_semantic!(calibration_reference["path"])
    module = selected_module!(representation_reference)
    source_references = Enum.map([baseline_source | control_sources], &source_reference/1)

    cond do
      spec.representation_id != representation_reference["representation_id"] or
        spec.method["name"] != representation_reference["method_name"] or
          spec.method["version"] != representation_reference["method_version"] ->
        Mix.raise("Frozen representation metadata changed")

      spec.git_revision != freeze["method_git_revision"] or
          calibration.git_revision != freeze["method_git_revision"] ->
        Mix.raise("Frozen method provenance changed")

      spec.fit_sources != source_references or calibration.source_runs != source_references ->
        Mix.raise("Frozen representation fit/null sources changed")

      calibration.calibration_id != calibration_reference["calibration_id"] or
        hd(calibration.thresholds)["threshold"] != calibration_reference["threshold"] or
        calibration.settings["seed"] != calibration_reference["seed"] or
        calibration.settings["iterations"] != calibration_reference["iterations"] or
          calibration.settings["quantile"] != calibration_reference["quantile"] ->
        Mix.raise("Frozen calibration settings changed")

      calibration.representation["parameters_sha256"] !=
          representation_reference["parameters_sha256"] ->
        Mix.raise("Frozen representation parameters changed")

      true ->
        fit_documents =
          Enum.flat_map([baseline_source | control_sources], fn source ->
            Comparison.completed_outputs(source.run, CheapBenchmarkConfig.case_id())
          end)

        model =
          case Representation.fit(module, fit_documents) do
            {:ok, model} -> model
            {:error, error} -> Mix.raise(format_error(error, "Could not refit frozen method"))
          end

        %{
          spec: spec,
          spec_sha256: representation_reference["artifact_sha256"],
          model: model,
          calibration: calibration,
          calibration_sha256: calibration_reference["artifact_sha256"]
        }
    end
  end

  defp selected_module!(reference) do
    case Enum.find(CheapBenchmarkConfig.representation_modules(), fn module ->
           module.method_name() == reference["method_name"] and
             module.method_version() == reference["method_version"]
         end) do
      nil -> Mix.raise("Frozen representation implementation is unavailable")
      module -> module
    end
  end

  defp read_heldout_fixtures!(reference) do
    verify_hash!(reference["path"], reference["artifact_sha256"])
    fixtures = read_semantic!(reference["path"])

    if fixtures.fixture_set_id == reference["fixture_set_id"] and fixtures.status == "approved",
      do: fixtures,
      else: Mix.raise("Frozen held-out fixture identity changed")
  end

  defp read_frozen_run!(config) do
    verify_hash!(config.path, config.artifact_sha256)

    case Storage.read(config.path) do
      {:ok, run} when run.run_id == config.run_id and run.condition == config.condition ->
        %{run: run, artifact_sha256: config.artifact_sha256}

      {:ok, run} ->
        Mix.raise("Frozen run identity changed at #{config.path}: #{inspect(run.run_id)}")

      {:error, error} ->
        Mix.raise(format_error(error, "Could not read frozen run"))
    end
  end

  defp read_semantic!(path) do
    case SemanticStorage.read(path) do
      {:ok, artifact} -> artifact
      {:error, error} -> Mix.raise(format_error(error, "Could not read semantic artifact"))
    end
  end

  defp source_reference(source) do
    %{
      "run_id" => source.run.run_id,
      "condition" => source.run.condition,
      "artifact_sha256" => source.artifact_sha256
    }
  end

  defp write!(path, result) do
    case SemanticStorage.write(path, result) do
      :ok -> :ok
      {:error, error} -> Mix.raise(format_error(error, "Could not write held-out result"))
    end
  end

  defp print_result(result, dry_run?) do
    heading =
      if dry_run?,
        do: "Semantic held-out benchmark (dry run)",
        else: "Semantic held-out benchmark captured"

    representation = hd(result.summary["by_representation"])
    Mix.shell().info(heading)
    Mix.shell().info("Artifact: #{@output_path}")
    Mix.shell().info("Evaluation: #{result.result_id}")
    Mix.shell().info("Representation: #{representation["representation_id"]}")

    Mix.shell().info(
      "Harmless reviews: #{representation["harmless_drift_review_count"]}/" <>
        "#{representation["harmless_comparison_count"]}"
    )

    Mix.shell().info(
      "Subtle reviews: #{representation["subtle_drift_review_count"]}/" <>
        "#{representation["subtle_comparison_count"]}"
    )

    Mix.shell().info("Stable across seeds: #{representation["stable_across_seeds"]}")
    Mix.shell().info("Decision gate: #{result.summary["gate_status"]}")
    Mix.shell().info("Provider calls: 0")

    if dry_run?,
      do: Mix.shell().info("No artifact was written."),
      else: Mix.shell().info("Frozen inputs were not changed.")
  end

  defp ensure_clean_worktree! do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> :ok
      {output, 0} -> Mix.raise("Commit the pre-held-out freeze before evaluation:\n#{output}")
      {output, status} -> Mix.raise("Could not inspect git status (#{status}): #{output}")
    end
  end

  defp git_revision! do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      {output, status} -> Mix.raise("Could not read git revision (#{status}): #{output}")
    end
  end

  defp verify_hash!(path, expected) do
    case File.read(path) do
      {:ok, contents} ->
        actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
        if actual != expected, do: Mix.raise("Frozen artifact hash changed at #{path}: #{actual}")

      {:error, reason} ->
        Mix.raise("Could not read frozen artifact #{path}: #{inspect(reason)}")
    end
  end

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end
end
