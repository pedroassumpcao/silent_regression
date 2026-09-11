defmodule Mix.Tasks.DriftSpike.BenchmarkSemanticTuning do
  @shortdoc "Benchmarks Task D representations on the approved tuning split"

  @moduledoc """
  Evaluates all three frozen local representations against the approved tuning
  batches and applies the predeclared selection rule. It never opens the
  held-out fixture artifact and makes zero provider calls.

  Run calibration first, commit all method code, then execute:

      mix drift_spike.calibrate_semantic_representations
      mix drift_spike.benchmark_semantic_tuning

  Use `--dry-run` to print the result without persisting it.
  """

  use Mix.Task

  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfig
  alias SilentRegression.Spike.SemanticLayer.Representation
  alias SilentRegression.Spike.SemanticLayer.RepresentationBenchmark
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Storage

  @switches [dry_run: :boolean, help: :boolean]
  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, [], []} ->
        if Keyword.get(options, :help, false),
          do: Mix.shell().info(@moduledoc),
          else: benchmark(Keyword.get(options, :dry_run, false))

      {_options, remaining, invalid} ->
        Mix.raise("Invalid semantic benchmark arguments: #{inspect(remaining ++ invalid)}")
    end
  end

  defp benchmark(dry_run?) do
    ensure_clean_worktree!()
    git_revision = git_revision!()
    baseline_source = read_frozen_run!(CheapBenchmarkConfig.baseline())
    control_sources = Enum.map(CheapBenchmarkConfig.fit_controls(), &read_frozen_run!/1)
    fixture_config = CheapBenchmarkConfig.tuning()
    fixtures = read_frozen_fixtures!(fixture_config)
    bundles = load_bundles!(baseline_source, control_sources, git_revision)
    settings = CheapBenchmarkConfig.settings()
    output_path = output_path(settings.tuning_iteration)

    result =
      case RepresentationBenchmark.run(
             baseline_source.run,
             fixtures,
             fixture_config.artifact_sha256,
             bundles,
             evaluation_role: "method_selection",
             seeds: settings.evaluation_seeds,
             permutations: settings.permutations,
             adjusted_p_alpha: settings.adjusted_p_alpha,
             harmless_review_rate_maximum: settings.harmless_review_rate_maximum,
             subtle_review_rate_minimum: settings.subtle_review_rate_minimum,
             multiple_comparison_family: settings.multiple_comparison_family,
             result_id: "semantic-benchmark-method-selection-v#{settings.tuning_iteration}",
             git_revision: git_revision
           ) do
        {:ok, result} -> result
        {:error, error} -> Mix.raise(format_error(error, "Semantic tuning benchmark failed"))
      end

    unless dry_run?, do: write!(output_path, result)
    print_result(result, output_path, dry_run?)
  end

  defp load_bundles!(baseline_source, control_sources, git_revision) do
    fit_documents =
      Enum.flat_map([baseline_source | control_sources], fn source ->
        Comparison.completed_outputs(source.run, CheapBenchmarkConfig.case_id())
      end)

    Enum.map(CheapBenchmarkConfig.representation_modules(), fn module ->
      slug = module.method_name() |> String.replace("_", "-")
      representation_id = "semantic-representation-#{slug}-v#{module.method_version()}"
      calibration_id = "semantic-calibration-#{slug}-v#{module.method_version()}"
      directory = CheapBenchmarkConfig.output_directory()
      spec_path = Path.join(directory, "#{representation_id}.json")
      calibration_path = Path.join(directory, "#{calibration_id}.json")
      {spec, spec_sha256} = read_semantic_artifact!(spec_path)
      {calibration, calibration_sha256} = read_semantic_artifact!(calibration_path)

      if spec.git_revision != calibration.git_revision or
           not ancestor_revision?(spec.git_revision, git_revision) do
        Mix.raise(
          "Semantic artifacts do not share a committed ancestor of revision #{git_revision}"
        )
      end

      model =
        case Representation.fit(module, fit_documents) do
          {:ok, model} -> model
          {:error, error} -> Mix.raise(format_error(error, "Could not refit representation"))
        end

      %{
        spec: spec,
        spec_sha256: spec_sha256,
        model: model,
        calibration: calibration,
        calibration_sha256: calibration_sha256
      }
    end)
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

  defp read_frozen_fixtures!(config) do
    verify_hash!(config.path, config.artifact_sha256)

    case SemanticStorage.read(config.path) do
      {:ok, fixtures}
      when fixtures.fixture_set_id == config.fixture_set_id and fixtures.status == "approved" ->
        fixtures

      {:ok, fixtures} ->
        Mix.raise("Frozen fixture identity changed at #{config.path}: #{fixtures.fixture_set_id}")

      {:error, error} ->
        Mix.raise(format_error(error, "Could not read tuning fixtures"))
    end
  end

  defp read_semantic_artifact!(path) do
    case SemanticStorage.read(path) do
      {:ok, artifact} -> {artifact, file_sha256!(path)}
      {:error, error} -> Mix.raise(format_error(error, "Could not read semantic artifact"))
    end
  end

  defp write!(path, result) do
    case SemanticStorage.write(path, result) do
      :ok -> :ok
      {:error, error} -> Mix.raise(format_error(error, "Could not write tuning result"))
    end
  end

  defp print_result(result, output_path, dry_run?) do
    heading =
      if dry_run?,
        do: "Semantic tuning benchmark (dry run)",
        else: "Semantic tuning benchmark captured"

    Mix.shell().info(heading)
    Mix.shell().info("Artifact: #{output_path}")
    Mix.shell().info("Evaluation: #{result.result_id}")
    Mix.shell().info("Seeds: #{Enum.join(result.settings["seeds"], ", ")}")

    Mix.shell().info(
      "Multiple-comparison family: #{result.settings["multiple_comparison_family"]}"
    )

    Enum.each(result.summary["by_representation"], fn representation ->
      Mix.shell().info("- #{representation["representation_id"]}")

      Mix.shell().info(
        "  harmless reviews: #{representation["harmless_drift_review_count"]}/" <>
          "#{representation["harmless_comparison_count"]}"
      )

      Mix.shell().info(
        "  subtle reviews: #{representation["subtle_drift_review_count"]}/" <>
          "#{representation["subtle_comparison_count"]}"
      )

      Mix.shell().info("  stable: #{representation["stable_across_seeds"]}")
      Mix.shell().info("  tuning gate: #{representation["passes_gate"]}")

      Mix.shell().info(
        "  separation margin: #{format_number(representation["separation_margin"])}"
      )
    end)

    selected = result.summary["selected_representation_ids"]
    Mix.shell().info("Selection gate: #{result.summary["gate_status"]}")

    Mix.shell().info(
      "Selected: #{if(selected == [], do: "none", else: Enum.join(selected, ", "))}"
    )

    Mix.shell().info("Provider calls: 0")

    if dry_run?,
      do: Mix.shell().info("No artifact was written and held-out fixtures were not read."),
      else: Mix.shell().info("Held-out fixtures were not read.")
  end

  defp ensure_clean_worktree! do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> :ok
      {output, 0} -> Mix.raise("Commit Task D code before benchmarking:\n#{output}")
      {output, status} -> Mix.raise("Could not inspect git status (#{status}): #{output}")
    end
  end

  defp output_path(iteration) do
    Path.join(
      CheapBenchmarkConfig.output_directory(),
      "semantic-benchmark-method-selection-v#{iteration}.json"
    )
  end

  defp git_revision! do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      {output, status} -> Mix.raise("Could not read git revision (#{status}): #{output}")
    end
  end

  defp ancestor_revision?(ancestor, current)
       when is_binary(ancestor) and is_binary(current) do
    case System.cmd("git", ["merge-base", "--is-ancestor", ancestor, current],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp ancestor_revision?(_ancestor, _current), do: false

  defp verify_hash!(path, expected) do
    actual = file_sha256!(path)
    if actual != expected, do: Mix.raise("Frozen artifact hash changed at #{path}: #{actual}")
  end

  defp file_sha256!(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:error, reason} -> Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp format_number(value), do: :erlang.float_to_binary(value, decimals: 6)

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end
end
