defmodule SilentRegression.Spike.Comparison do
  @moduledoc """
  Provenance-safe baseline/candidate comparison for the drift spike.

  Lexical comparisons use only successful, complete outputs. Raw permutation
  p-values are corrected across every case in a run. A drift-review outcome is
  available only when an independently created calibration artifact both
  matches the baseline provenance and excludes the candidate run from its null
  sources.
  """

  alias SilentRegression.Spike.Calibration
  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.Statistics

  @dynamic_request_keys ["model_availability", "samples_per_case"]

  @type result :: %{required(String.t()) => term()}

  @doc "Returns the stable configuration identity used for run compatibility."
  @spec provenance(Run.t()) :: map()
  def provenance(%Run{} = run) do
    %{
      "provider" => run.provider,
      "request_config" => behavior_request_config(run.request_config),
      "returned_models" => returned_models(run),
      "cases" => Enum.map(run.cases, &case_summary/1)
    }
  end

  @doc "Validates a planned capture against an existing baseline before provider calls."
  @spec validate_capture_plan(Run.t(), map()) :: :ok | {:error, map()}
  def validate_capture_plan(%Run{} = baseline, plan) when is_map(plan) do
    with :ok <- validate_baseline(baseline),
         :ok <- compare_value("provider", baseline.provider, plan["provider"]),
         :ok <-
           compare_value(
             "request_config",
             behavior_request_config(baseline.request_config),
             plan["request_config"]
           ),
         :ok <-
           compare_value(
             "cases",
             Enum.map(baseline.cases, &case_summary/1),
             plan["cases"]
           ) do
      :ok
    end
  end

  def validate_capture_plan(_baseline, _plan),
    do: configuration_error("A baseline run and capture plan are required")

  @doc "Validates exact run provenance and baseline/candidate conditions."
  @spec validate_runs(Run.t(), Run.t()) :: :ok | {:error, map()}
  def validate_runs(%Run{} = baseline, %Run{} = candidate) do
    with :ok <- validate_baseline(baseline),
         :ok <- validate_candidate(candidate),
         :ok <- ensure_distinct_run_ids(baseline, candidate),
         :ok <- compare_value("provenance", provenance(baseline), provenance(candidate)) do
      :ok
    end
  end

  def validate_runs(_baseline, _candidate),
    do: configuration_error("Baseline and candidate run artifacts are required")

  @doc "Validates that frozen thresholds can be applied to a planned held-out run."
  @spec validate_calibration_for_plan(Calibration.t() | nil, Run.t(), map()) ::
          :ok | {:error, map()}
  def validate_calibration_for_plan(nil, _baseline, _plan), do: :ok

  def validate_calibration_for_plan(%Calibration{} = calibration, %Run{} = baseline, plan)
      when is_map(plan) do
    expected_case_ids = Enum.map(baseline.cases, & &1.id)
    threshold_case_ids = Enum.map(calibration.thresholds, & &1["case_id"])

    cond do
      calibration.baseline_run_id != baseline.run_id ->
        incompatible("calibration.baseline_run_id", baseline.run_id, calibration.baseline_run_id)

      calibration.provenance != provenance(baseline) ->
        incompatible("calibration.provenance", provenance(baseline), calibration.provenance)

      threshold_case_ids != expected_case_ids ->
        incompatible("calibration.case_ids", expected_case_ids, threshold_case_ids)

      plan["run_id"] in calibration.source_run_ids ->
        {:error,
         Provider.error(
           :calibration_leakage,
           "A calibration source run ID cannot be reused for a held-out candidate",
           details: %{
             "calibration_id" => calibration.calibration_id,
             "candidate_run_id" => plan["run_id"]
           }
         )}

      true ->
        :ok
    end
  end

  def validate_calibration_for_plan(_calibration, _baseline, _plan),
    do: configuration_error("Calibration planning requires valid artifacts and a plan")

  @doc "Returns successful, complete output text for one case in stable sample order."
  @spec completed_outputs(Run.t(), String.t()) :: [String.t()]
  def completed_outputs(%Run{} = run, case_id) when is_binary(case_id) do
    run.samples
    |> Enum.filter(fn sample ->
      sample["case_id"] == case_id and sample["status"] == "ok" and
        get_in(sample, ["completion", "passed"]) == true
    end)
    |> Enum.sort_by(& &1["sample_index"])
    |> Enum.map(&get_in(&1, ["response", "output_text"]))
    |> Enum.filter(&is_binary/1)
  end

  @doc "Compares a candidate run to its baseline, optionally applying frozen thresholds."
  @spec compare(Run.t(), Run.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def compare(baseline, candidate, options \\ [])

  def compare(%Run{} = baseline, %Run{} = candidate, options) when is_list(options) do
    with :ok <- validate_compare_options(options),
         {:ok, seed} <- required_integer(options, :seed),
         {:ok, permutations} <- positive_integer(options, :permutations, 999),
         {:ok, calibration} <- optional_calibration(options),
         :ok <- validate_runs(baseline, candidate),
         :ok <- validate_calibration(calibration, baseline, candidate),
         {:ok, unadjusted} <- compare_cases(baseline, candidate, seed, permutations),
         {:ok, adjusted_p_values} <-
           Statistics.benjamini_hochberg(Enum.map(unadjusted, & &1["p_value"])) do
      by_case =
        unadjusted
        |> Enum.zip(adjusted_p_values)
        |> Enum.map(fn {comparison, adjusted_p_value} ->
          comparison
          |> Map.put("adjusted_p_value", adjusted_p_value)
          |> apply_threshold(calibration)
        end)

      {:ok,
       %{
         "baseline_run_id" => baseline.run_id,
         "candidate_run_id" => candidate.run_id,
         "candidate_condition" => candidate.condition,
         "seed" => seed,
         "permutations" => permutations,
         "calibration_id" => calibration_id(calibration),
         "by_case" => by_case,
         "summary" => %{
           "case_count" => length(by_case),
           "drift_review_count" => Enum.count(by_case, &(&1["outcome"] == "drift_review")),
           "not_calibrated_count" => Enum.count(by_case, &(&1["outcome"] == "not_calibrated"))
         }
       }}
    end
  end

  def compare(_baseline, _candidate, _options),
    do: configuration_error("Comparison options must be a keyword list")

  defp validate_compare_options(options) do
    if Keyword.keyword?(options) do
      allowed = [:calibration, :permutations, :seed]
      keys = Keyword.keys(options)

      cond do
        Enum.uniq(keys) != keys ->
          configuration_error("Comparison options must be unique")

        keys -- allowed != [] ->
          configuration_error("Comparison options contain unsupported keys",
            unsupported_options: Enum.map(keys -- allowed, &Atom.to_string/1)
          )

        true ->
          :ok
      end
    else
      configuration_error("Comparison options must be a keyword list")
    end
  end

  defp optional_calibration(options) do
    case Keyword.get(options, :calibration) do
      nil -> {:ok, nil}
      %Calibration{} = calibration -> {:ok, calibration}
      _value -> configuration_error("Calibration must be a calibration artifact")
    end
  end

  defp compare_cases(baseline, candidate, seed, permutations) do
    baseline.cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {%Case{} = case_definition, index}, {:ok, results} ->
      baseline_outputs = completed_outputs(baseline, case_definition.id)
      candidate_outputs = completed_outputs(candidate, case_definition.id)
      case_seed = seed + index

      case Statistics.permutation_test(baseline_outputs, candidate_outputs,
             seed: case_seed,
             permutations: permutations
           ) do
        {:ok, lexical} ->
          result = %{
            "case_id" => case_definition.id,
            "case_fingerprint" => case_definition.fingerprint,
            "seed" => case_seed,
            "baseline_completed_samples" => length(baseline_outputs),
            "candidate_completed_samples" => length(candidate_outputs),
            "energy_distance" => lexical["observed_energy"],
            "within_baseline_mean" => lexical["observed"]["within_reference_mean"],
            "within_candidate_mean" => lexical["observed"]["within_candidate_mean"],
            "cross_mean" => lexical["observed"]["cross_mean"],
            "p_value" => lexical["p_value"],
            "extreme_permutations" => lexical["extreme_permutations"],
            "permutations" => lexical["permutations"],
            "quality" =>
              rate_change(baseline, candidate, case_definition.id, "quality", "pass_rate"),
            "deterministic" =>
              rate_change(
                baseline,
                candidate,
                case_definition.id,
                "deterministic",
                "sample_pass_rate"
              )
          }

          {:cont, {:ok, [result | results]}}

        {:error, error} ->
          {:halt,
           {:error,
            Provider.error(:comparison_failed, "Case comparison could not be calculated",
              details: %{
                "case_id" => case_definition.id,
                "reason" => inspect(error)
              }
            )}}
      end
    end)
    |> then(fn
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, error} -> {:error, error}
    end)
  end

  defp rate_change(baseline, candidate, case_id, section, field) do
    baseline_rate = metric_rate(baseline, case_id, section, field)
    candidate_rate = metric_rate(candidate, case_id, section, field)

    %{
      "baseline_rate" => baseline_rate,
      "candidate_rate" => candidate_rate,
      "change" => numeric_change(candidate_rate, baseline_rate)
    }
  end

  defp metric_rate(run, case_id, section, field) do
    run.metrics
    |> Map.get("by_case", [])
    |> Enum.find(&(&1["case_id"] == case_id))
    |> case do
      nil -> nil
      metrics -> get_in(metrics, [section, field])
    end
  end

  defp numeric_change(candidate_rate, baseline_rate)
       when is_number(candidate_rate) and is_number(baseline_rate),
       do: candidate_rate - baseline_rate

  defp numeric_change(_candidate_rate, _baseline_rate), do: nil

  defp apply_threshold(comparison, nil) do
    comparison
    |> Map.put("threshold", nil)
    |> Map.put("above_threshold", nil)
    |> Map.put("adjusted_p_alpha", nil)
    |> Map.put("statistically_significant", nil)
    |> Map.put("outcome", "not_calibrated")
  end

  defp apply_threshold(comparison, %Calibration{} = calibration) do
    threshold = Enum.find(calibration.thresholds, &(&1["case_id"] == comparison["case_id"]))
    threshold_value = threshold["threshold"]
    alpha = calibration.settings["adjusted_p_alpha"]
    above_threshold = comparison["energy_distance"] > threshold_value
    statistically_significant = comparison["adjusted_p_value"] <= alpha

    outcome =
      if above_threshold and statistically_significant,
        do: "drift_review",
        else: "no_drift_review"

    comparison
    |> Map.put("threshold", threshold_value)
    |> Map.put("above_threshold", above_threshold)
    |> Map.put("adjusted_p_alpha", alpha)
    |> Map.put("statistically_significant", statistically_significant)
    |> Map.put("outcome", outcome)
  end

  defp validate_calibration(nil, _baseline, _candidate), do: :ok

  defp validate_calibration(%Calibration{} = calibration, baseline, candidate) do
    expected_case_ids = Enum.map(baseline.cases, & &1.id)
    threshold_case_ids = Enum.map(calibration.thresholds, & &1["case_id"])
    expected_candidate_size = calibration.settings["control_group_size"]

    candidate_sizes =
      Map.new(candidate.cases, fn case_definition ->
        {case_definition.id, completed_outputs(candidate, case_definition.id) |> length()}
      end)

    cond do
      calibration.baseline_run_id != baseline.run_id ->
        incompatible("calibration.baseline_run_id", baseline.run_id, calibration.baseline_run_id)

      calibration.provenance != provenance(baseline) ->
        incompatible("calibration.provenance", provenance(baseline), calibration.provenance)

      threshold_case_ids != expected_case_ids ->
        incompatible("calibration.case_ids", expected_case_ids, threshold_case_ids)

      candidate.run_id in calibration.source_run_ids ->
        {:error,
         Provider.error(
           :calibration_leakage,
           "A calibration source run cannot be evaluated as a held-out candidate",
           details: %{
             "calibration_id" => calibration.calibration_id,
             "candidate_run_id" => candidate.run_id
           }
         )}

      Enum.any?(candidate_sizes, fn {_case_id, size} -> size != expected_candidate_size end) ->
        {:error,
         Provider.error(
           :incompatible_sample_shape,
           "Held-out samples do not match the frozen calibration group size",
           details: %{
             "calibration_id" => calibration.calibration_id,
             "expected_complete_samples_per_case" => expected_candidate_size,
             "actual_complete_samples_by_case" => candidate_sizes
           }
         )}

      true ->
        :ok
    end
  end

  defp validate_baseline(%Run{condition: "baseline"} = run) do
    validate_case_snapshots(run)
  end

  defp validate_baseline(%Run{} = run) do
    incompatible("baseline.condition", "baseline", run.condition)
  end

  defp validate_candidate(%Run{condition: condition} = run) when condition != "baseline" do
    validate_case_snapshots(run)
  end

  defp validate_candidate(%Run{} = run) do
    incompatible("candidate.condition", "non-baseline", run.condition)
  end

  defp validate_case_snapshots(run) do
    case CaseSet.validate(run.cases) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Provider.error(:invalid_case_snapshot, "Run contains an invalid case snapshot",
           details: %{"run_id" => run.run_id, "reason" => inspect(reason)}
         )}
    end
  end

  defp ensure_distinct_run_ids(%Run{run_id: run_id}, %Run{run_id: run_id}) do
    {:error,
     Provider.error(:invalid_comparison, "A run cannot be compared with itself",
       details: %{"run_id" => run_id}
     )}
  end

  defp ensure_distinct_run_ids(_baseline, _candidate), do: :ok

  defp compare_value(_field, value, value), do: :ok
  defp compare_value(field, expected, actual), do: incompatible(field, expected, actual)

  defp incompatible(field, expected, actual) do
    {:error,
     Provider.error(:incompatible_provenance, "Run provenance is incompatible",
       details: %{
         "field" => field,
         "expected" => expected,
         "actual" => actual
       }
     )}
  end

  defp behavior_request_config(request_config) when is_map(request_config) do
    Map.drop(request_config, @dynamic_request_keys)
  end

  defp behavior_request_config(_request_config), do: nil

  defp returned_models(run) do
    run.totals
    |> Map.get("returned_models", %{})
    |> Map.keys()
    |> Enum.sort()
  end

  defp case_summary(case_definition) do
    %{
      "id" => case_definition.id,
      "version" => case_definition.version,
      "fingerprint" => case_definition.fingerprint
    }
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

  defp calibration_id(nil), do: nil
  defp calibration_id(%Calibration{calibration_id: calibration_id}), do: calibration_id

  defp configuration_error(message, details \\ []) do
    {:error,
     Provider.error(:configuration_error, message,
       details: Map.new(details, fn {key, value} -> {Atom.to_string(key), value} end)
     )}
  end
end
