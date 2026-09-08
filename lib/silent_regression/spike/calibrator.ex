defmodule SilentRegression.Spike.Calibrator do
  @moduledoc """
  Builds per-case empirical lexical thresholds from baseline/control data only.

  Every source run must have identical provenance and a complete sample pool.
  Resampling uses the original baseline and control group sizes so the frozen
  threshold matches the comparison shape used by later held-out runs.
  """

  alias SilentRegression.Spike.Calibration
  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.Statistics

  @allowed_options [
    :adjusted_p_alpha,
    :calibration_id,
    :clock,
    :git_revision,
    :iterations,
    :quantile,
    :seed
  ]

  @doc "Builds a validated calibration artifact without persisting it."
  @spec build(Run.t(), [Run.t()], keyword()) :: {:ok, Calibration.t()} | {:error, map()}
  def build(%Run{} = baseline, controls, options) when is_list(controls) and is_list(options) do
    with :ok <- validate_options(options),
         {:ok, seed} <- required_integer(options, :seed),
         {:ok, iterations} <- positive_integer(options, :iterations, 200),
         {:ok, quantile} <- probability(options, :quantile, 0.95),
         {:ok, adjusted_p_alpha} <- probability(options, :adjusted_p_alpha, 0.05),
         :ok <- validate_controls(baseline, controls),
         {:ok, baseline_size, control_size} <- validate_sample_shapes(baseline, controls),
         {:ok, created_at} <- timestamp(options),
         {:ok, calibration_id} <- calibration_id(options, created_at),
         {:ok, git_revision} <- git_revision(options),
         {:ok, thresholds} <-
           build_thresholds(
             baseline,
             controls,
             seed,
             iterations,
             quantile,
             baseline_size,
             control_size
           ) do
      control_run_ids = Enum.map(controls, & &1.run_id)

      Calibration.new(%{
        calibration_id: calibration_id,
        created_at: created_at,
        git_revision: git_revision,
        baseline_run_id: baseline.run_id,
        control_run_ids: control_run_ids,
        source_run_ids: [baseline.run_id | control_run_ids],
        provenance: Comparison.provenance(baseline),
        settings: %{
          "seed" => seed,
          "iterations" => iterations,
          "quantile" => quantile,
          "adjusted_p_alpha" => adjusted_p_alpha,
          "baseline_group_size" => baseline_size,
          "control_group_size" => control_size
        },
        thresholds: thresholds
      })
    end
  end

  def build(_baseline, _controls, _options),
    do: configuration_error("A baseline, a control list, and keyword options are required")

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        configuration_error("Calibration options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        configuration_error("Calibration options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        configuration_error("Calibration options contain unsupported keys",
          unsupported_options:
            Enum.map(Keyword.keys(options) -- @allowed_options, &Atom.to_string/1)
        )

      true ->
        :ok
    end
  end

  defp validate_controls(_baseline, []) do
    configuration_error("At least one control run is required for calibration")
  end

  defp validate_controls(baseline, controls) do
    run_ids = Enum.map(controls, &run_id/1)

    cond do
      not Enum.all?(controls, &match?(%Run{condition: "control"}, &1)) ->
        configuration_error("Calibration sources must all be control runs")

      Enum.uniq(run_ids) != run_ids ->
        configuration_error("Calibration control run IDs must be unique")

      true ->
        Enum.reduce_while(controls, :ok, fn control, :ok ->
          case Comparison.validate_runs(baseline, control) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
    end
  end

  defp run_id(%Run{run_id: run_id}), do: run_id
  defp run_id(_run), do: nil

  defp validate_sample_shapes(baseline, controls) do
    baseline_size = baseline.request_config["samples_per_case"]
    control_sizes = Enum.map(controls, & &1.request_config["samples_per_case"])

    cond do
      not (is_integer(baseline_size) and baseline_size >= 2) ->
        configuration_error("Baseline samples_per_case must be at least two")

      not Enum.all?(control_sizes, &(is_integer(&1) and &1 >= 2)) ->
        configuration_error("Control samples_per_case must be at least two")

      Enum.uniq(control_sizes) |> length() != 1 ->
        configuration_error("All calibration controls must use the same samples_per_case",
          control_sample_sizes: control_sizes
        )

      true ->
        control_size = hd(control_sizes)

        with :ok <- validate_complete_run(baseline, baseline_size),
             :ok <- validate_complete_runs(controls, control_size) do
          {:ok, baseline_size, control_size}
        end
    end
  end

  defp validate_complete_runs(controls, expected_size) do
    Enum.reduce_while(controls, :ok, fn control, :ok ->
      case validate_complete_run(control, expected_size) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_complete_run(run, expected_size) do
    incomplete_cases =
      Enum.flat_map(run.cases, fn case_definition ->
        completed = Comparison.completed_outputs(run, case_definition.id) |> length()

        if completed == expected_size do
          []
        else
          [
            %{
              "case_id" => case_definition.id,
              "expected_complete_samples" => expected_size,
              "actual_complete_samples" => completed
            }
          ]
        end
      end)

    if incomplete_cases == [] do
      :ok
    else
      {:error,
       Provider.error(
         :incomplete_calibration_source,
         "Calibration sources require a complete sample pool for every case",
         details: %{"run_id" => run.run_id, "cases" => incomplete_cases}
       )}
    end
  end

  defp build_thresholds(
         baseline,
         controls,
         seed,
         iterations,
         quantile,
         baseline_size,
         control_size
       ) do
    baseline.cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {case_definition, index}, {:ok, thresholds} ->
      case_seed = seed + index
      batches = calibration_batches(baseline, controls, case_definition.id)

      options = [
        seed: case_seed,
        iterations: iterations,
        quantile: quantile,
        reference_size: baseline_size,
        candidate_size: control_size
      ]

      case Statistics.calibrate_threshold(batches, options) do
        {:ok, calibration} ->
          null_energies = calibration["null_energies"]
          {:ok, null_summary} = Statistics.summarize(null_energies)
          exceedance_count = Enum.count(null_energies, &(&1 > calibration["threshold"]))

          threshold = %{
            "case_id" => case_definition.id,
            "case_fingerprint" => case_definition.fingerprint,
            "seed" => case_seed,
            "threshold" => calibration["threshold"],
            "quantile" => calibration["quantile"],
            "iterations" => calibration["iterations"],
            "reference_size" => calibration["reference_size"],
            "candidate_size" => calibration["candidate_size"],
            "source_conditions" => calibration["source_conditions"],
            "source_counts" => calibration["source_counts"],
            "source_sample_counts" =>
              source_sample_counts(baseline, controls, case_definition.id),
            "null_energies" => null_energies,
            "null_summary" => null_summary,
            "empirical_exceedance_count" => exceedance_count,
            "empirical_exceedance_rate" => exceedance_count / length(null_energies)
          }

          {:cont, {:ok, [threshold | thresholds]}}

        {:error, error} ->
          {:halt,
           {:error,
            Provider.error(:calibration_failed, "Case threshold could not be calibrated",
              details: %{"case_id" => case_definition.id, "reason" => inspect(error)}
            )}}
      end
    end)
    |> then(fn
      {:ok, thresholds} -> {:ok, Enum.reverse(thresholds)}
      {:error, error} -> {:error, error}
    end)
  end

  defp calibration_batches(baseline, controls, case_id) do
    [baseline | controls]
    |> Enum.map(fn run ->
      %{
        "condition" => run.condition,
        "samples" => Comparison.completed_outputs(run, case_id)
      }
    end)
  end

  defp source_sample_counts(baseline, controls, case_id) do
    Map.new([baseline | controls], fn run ->
      {run.run_id, Comparison.completed_outputs(run, case_id) |> length()}
    end)
  end

  defp required_integer(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> configuration_error("#{name} must be an integer")
      :error -> configuration_error("#{name} is required")
    end
  end

  defp positive_integer(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      configuration_error("#{name} must be a positive integer")
    end
  end

  defp probability(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_number(value) and value > 0 and value < 1 do
      {:ok, value * 1.0}
    else
      configuration_error("#{name} must be greater than zero and less than one")
    end
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp -> {:ok, timestamp}
      _value -> configuration_error("Calibration clock must return a DateTime")
    end
  rescue
    exception ->
      configuration_error("Calibration clock raised", exception: inspect(exception.__struct__))
  end

  defp calibration_id(options, timestamp) do
    value =
      Keyword.get_lazy(options, :calibration_id, fn ->
        formatted = Calendar.strftime(timestamp, "%Y%m%dT%H%M%SZ")
        suffix = System.unique_integer([:positive, :monotonic])
        "calibration-#{formatted}-#{suffix}"
      end)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      configuration_error("Calibration ID must be a non-empty string")
    end
  end

  defp git_revision(options) do
    value = Keyword.get_lazy(options, :git_revision, &current_git_revision/0)

    if is_nil(value) or (is_binary(value) and String.trim(value) != "") do
      {:ok, value}
    else
      configuration_error("Calibration git revision must be nil or a non-empty string")
    end
  end

  defp current_git_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} ->
        case String.trim(revision) do
          "" -> nil
          value -> value
        end

      {_output, _status} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp configuration_error(message, details \\ []) do
    {:error,
     Provider.error(:configuration_error, message,
       details: Map.new(details, fn {key, value} -> {Atom.to_string(key), value} end)
     )}
  end
end
