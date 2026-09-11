defmodule Mix.Tasks.DriftSpike.CalibrateSemanticRepresentations do
  @shortdoc "Fits and calibrates the frozen Task D local representations"

  @moduledoc """
  Fits the three predeclared Task D representations using only the frozen
  baseline and the two controls reserved for null fitting. It then creates one
  representation specification and calibration artifact per method.

      mix drift_spike.calibrate_semantic_representations

  This task is local and makes zero provider calls. Use `--dry-run` to validate
  and hash all six artifacts without writing them.
  """

  use Mix.Task

  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfig
  alias SilentRegression.Spike.SemanticLayer.RepresentationCalibrator
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
          else: calibrate(Keyword.get(options, :dry_run, false))

      {_options, remaining, invalid} ->
        Mix.raise("Invalid semantic calibration arguments: #{inspect(remaining ++ invalid)}")
    end
  end

  defp calibrate(dry_run?) do
    git_revision = git_revision!()
    baseline = read_frozen_source!(CheapBenchmarkConfig.baseline())
    controls = Enum.map(CheapBenchmarkConfig.fit_controls(), &read_frozen_source!/1)
    settings = CheapBenchmarkConfig.settings()

    bundles =
      Enum.map(CheapBenchmarkConfig.representation_modules(), fn module ->
        case RepresentationCalibrator.build(module, baseline, controls,
               case_id: CheapBenchmarkConfig.case_id(),
               excluded_run_ids: CheapBenchmarkConfig.excluded_fit_run_ids(),
               seed: settings.calibration_seed,
               iterations: settings.calibration_iterations,
               quantile: settings.quantile,
               adjusted_p_alpha: settings.adjusted_p_alpha,
               git_revision: git_revision
             ) do
          {:ok, bundle} -> bundle
          {:error, error} -> Mix.raise(format_error(error, "Semantic calibration failed"))
        end
      end)

    Enum.each(bundles, &persist_or_print!(&1, dry_run?))
    Mix.shell().info("Provider calls: 0")

    if dry_run?,
      do: Mix.shell().info("No artifacts were written."),
      else: Mix.shell().info("Six immutable Task D artifacts were written.")
  end

  defp read_frozen_source!(config) do
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

  defp persist_or_print!(bundle, dry_run?) do
    directory = CheapBenchmarkConfig.output_directory()
    spec_path = Path.join(directory, "#{bundle.spec.representation_id}.json")
    calibration_path = Path.join(directory, "#{bundle.calibration.calibration_id}.json")

    unless dry_run? do
      write!(spec_path, bundle.spec)
      write!(calibration_path, bundle.calibration)
    end

    threshold = hd(bundle.calibration.thresholds)
    Mix.shell().info("Representation: #{bundle.spec.representation_id}")
    Mix.shell().info("  Artifact: #{spec_path}")
    Mix.shell().info("  SHA-256: #{bundle.spec_sha256}")
    Mix.shell().info("  Calibration: #{calibration_path}")
    Mix.shell().info("  Calibration SHA-256: #{bundle.calibration_sha256}")
    Mix.shell().info("  Fit observations: #{length(bundle.spec.fit_observation_ids)}")
    Mix.shell().info("  Threshold: #{format_number(threshold["threshold"])}")
  end

  defp write!(path, artifact) do
    case SemanticStorage.write(path, artifact) do
      :ok -> :ok
      {:error, error} -> Mix.raise(format_error(error, "Could not write semantic artifact"))
    end
  end

  defp verify_hash!(path, expected) do
    case File.read(path) do
      {:ok, contents} ->
        actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

        if actual != expected,
          do: Mix.raise("Frozen artifact hash changed at #{path}: #{actual}")

      {:error, reason} ->
        Mix.raise("Could not read frozen artifact #{path}: #{inspect(reason)}")
    end
  end

  defp git_revision! do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      {output, status} -> Mix.raise("Could not read git revision (#{status}): #{output}")
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
