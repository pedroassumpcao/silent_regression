defmodule SilentRegression.Spike.RunAnalysis do
  @moduledoc """
  Scores successful samples and summarizes completion, quality, and within-run
  characteristics.

  The analysis is provider-neutral and reusable by baseline and control runs.
  Structured provider failures remain in the ordered sample list but do not
  contribute invented latency, usage, or lexical observations. Responses with
  incomplete finish reasons retain their real latency and usage, count as
  quality failures, and are excluded from lexical drift observations.
  """

  alias SilentRegression.Spike.DeterministicChecks
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Statistics

  @incomplete_finish_reasons ~w(
    cancelled
    failed
    in_progress
    length
    max_output_tokens
    max_tokens
    model_context_window_exceeded
    pause_turn
    queued
  )

  @type result :: %{required(String.t()) => term()}

  @doc "Returns ordered scored samples and per-case/overall run metrics."
  @spec analyze([SilentRegression.Spike.Case.t()], [map()]) ::
          {:ok, result()} | {:error, Provider.error()}
  def analyze(cases, samples) do
    with {:ok, scored_samples} <- score_samples(cases, samples) do
      {:ok,
       %{
         "samples" => scored_samples,
         "metrics" => build_metrics(cases, scored_samples)
       }}
    end
  end

  @doc "Returns successful-sample usage, latency, and returned-model totals."
  @spec success_totals([map()]) :: result()
  def success_totals(samples) do
    successful_samples = Enum.filter(samples, &(&1["status"] == "ok"))
    usage = usage_summary(successful_samples)

    latency =
      Enum.reduce(successful_samples, 0, &(get_in(&1, ["response", "latency_ms"]) + &2))

    returned_models =
      successful_samples
      |> Enum.map(&get_in(&1, ["response", "returned_model"]))
      |> Enum.frequencies()

    %{
      "latency_ms" => latency,
      "input_tokens" => usage["input_tokens"],
      "output_tokens" => usage["output_tokens"],
      "returned_models" => returned_models
    }
  end

  defp score_samples(cases, samples) do
    cases_by_id = Map.new(cases, &{&1.id, &1})

    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, scored_samples} ->
      case score_sample(sample, cases_by_id) do
        {:ok, scored_sample} -> {:cont, {:ok, [scored_sample | scored_samples]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, scored_samples} -> {:ok, Enum.reverse(scored_samples)}
      {:error, error} -> {:error, error}
    end)
  end

  defp score_sample(%{"status" => "error"} = sample, _cases_by_id), do: {:ok, sample}

  defp score_sample(%{"status" => "ok", "response" => response} = sample, cases_by_id) do
    with {:ok, case_definition} <- Map.fetch(cases_by_id, sample["case_id"]),
         output when is_binary(output) <- response["output_text"],
         {:ok, deterministic} <- DeterministicChecks.evaluate(case_definition, output) do
      completion = completion_evaluation(response["finish_reason"])
      quality = quality_evaluation(completion, deterministic)

      {:ok,
       sample
       |> Map.put("completion", completion)
       |> Map.put("deterministic", deterministic)
       |> Map.put("quality", quality)}
    else
      :error -> scoring_error(sample, :unknown_case)
      {:error, error} -> scoring_error(sample, error)
      _invalid_output -> scoring_error(sample, :invalid_output)
    end
  end

  defp score_sample(sample, _cases_by_id), do: scoring_error(sample, :invalid_sample)

  defp scoring_error(sample, reason) do
    {:error,
     Provider.error(:scoring_failed, "A successful sample could not be scored",
       details: %{
         "case_id" => if(is_map(sample), do: sample["case_id"], else: nil),
         "reason" => inspect(reason)
       }
     )}
  end

  defp build_metrics(cases, samples) do
    by_case =
      Enum.map(cases, fn case_definition ->
        case_samples = Enum.filter(samples, &(&1["case_id"] == case_definition.id))
        successful_samples = Enum.filter(case_samples, &(&1["status"] == "ok"))
        completed_samples = Enum.filter(successful_samples, &completed_sample?/1)

        %{
          "case_id" => case_definition.id,
          "case_fingerprint" => case_definition.fingerprint,
          "successful_samples" => length(successful_samples),
          "failed_samples" => Enum.count(case_samples, &(&1["status"] == "error")),
          "completion" => completion_summary(successful_samples),
          "quality" => quality_summary(case_samples),
          "deterministic" => deterministic_summary(successful_samples),
          "within_distance" =>
            within_distance_summary(
              completed_samples,
              length(successful_samples) - length(completed_samples)
            ),
          "latency_ms" => latency_summary(successful_samples),
          "usage" => usage_summary(successful_samples)
        }
      end)

    successful_samples = Enum.filter(samples, &(&1["status"] == "ok"))

    %{
      "by_case" => by_case,
      "overall" => %{
        "completion" => completion_summary(successful_samples),
        "quality" => quality_summary(samples),
        "deterministic" => deterministic_summary(successful_samples),
        "latency_ms" => latency_summary(successful_samples),
        "usage" => usage_summary(successful_samples)
      }
    }
  end

  defp completion_evaluation(nil) do
    %{
      "status" => "unknown",
      "passed" => false,
      "finish_reason" => nil,
      "reason" => "finish_reason_missing"
    }
  end

  defp completion_evaluation(finish_reason) do
    incomplete? =
      String.starts_with?(finish_reason, "incomplete:") or
        finish_reason in @incomplete_finish_reasons

    if incomplete? do
      %{
        "status" => "incomplete",
        "passed" => false,
        "finish_reason" => finish_reason,
        "reason" => "response_incomplete"
      }
    else
      %{
        "status" => "complete",
        "passed" => true,
        "finish_reason" => finish_reason,
        "reason" => "response_complete"
      }
    end
  end

  defp quality_evaluation(completion, deterministic) do
    deterministic_passed = deterministic["all_passed"]

    {passed, reason} =
      cond do
        not completion["passed"] -> {false, completion["reason"]}
        deterministic_passed == false -> {false, "deterministic_checks_failed"}
        true -> {true, "quality_checks_passed"}
      end

    %{
      "passed" => passed,
      "reason" => reason,
      "completion_passed" => completion["passed"],
      "deterministic_passed" => deterministic_passed
    }
  end

  defp completed_sample?(sample), do: get_in(sample, ["completion", "passed"]) == true

  defp completion_summary(samples) do
    statuses = Enum.map(samples, &get_in(&1, ["completion", "status"]))
    evaluated_samples = length(statuses)
    completed_samples = Enum.count(statuses, &(&1 == "complete"))

    finish_reasons =
      samples
      |> Enum.map(&(get_in(&1, ["completion", "finish_reason"]) || "missing"))
      |> Enum.frequencies()

    %{
      "evaluated_samples" => evaluated_samples,
      "completed_samples" => completed_samples,
      "incomplete_samples" => Enum.count(statuses, &(&1 == "incomplete")),
      "unknown_samples" => Enum.count(statuses, &(&1 == "unknown")),
      "completion_rate" => ratio(completed_samples, evaluated_samples),
      "finish_reasons" => finish_reasons
    }
  end

  defp quality_summary(samples) do
    passed_samples = Enum.count(samples, &(get_in(&1, ["quality", "passed"]) == true))

    failure_reasons =
      samples
      |> Enum.reject(&(get_in(&1, ["quality", "passed"]) == true))
      |> Enum.map(&quality_failure_reason/1)
      |> Enum.frequencies()

    evaluated_samples = length(samples)

    %{
      "evaluated_samples" => evaluated_samples,
      "passed_samples" => passed_samples,
      "failed_samples" => evaluated_samples - passed_samples,
      "pass_rate" => ratio(passed_samples, evaluated_samples),
      "failure_reasons" => failure_reasons
    }
  end

  defp quality_failure_reason(%{"status" => "error"}), do: "provider_error"

  defp quality_failure_reason(sample),
    do: get_in(sample, ["quality", "reason"]) || "quality_not_evaluated"

  defp deterministic_summary(samples) do
    evaluations = Enum.map(samples, & &1["deterministic"])
    evaluated_samples = length(evaluations)
    passed_samples = Enum.count(evaluations, & &1["all_passed"])
    passed_checks = Enum.reduce(evaluations, 0, &(&1["passed_checks"] + &2))
    total_checks = Enum.reduce(evaluations, 0, &(&1["total_checks"] + &2))

    %{
      "evaluated_samples" => evaluated_samples,
      "passed_samples" => passed_samples,
      "failed_samples" => evaluated_samples - passed_samples,
      "sample_pass_rate" => ratio(passed_samples, evaluated_samples),
      "passed_checks" => passed_checks,
      "total_checks" => total_checks,
      "check_pass_rate" => ratio(passed_checks, total_checks)
    }
  end

  defp within_distance_summary(samples, excluded_incomplete_samples) do
    outputs = Enum.map(samples, &get_in(&1, ["response", "output_text"]))

    case Statistics.within_distances(outputs) do
      {:ok, distances} ->
        distances
        |> numeric_summary()
        |> Map.put("status", "available")
        |> Map.put("successful_samples", length(outputs))
        |> Map.put("excluded_incomplete_samples", excluded_incomplete_samples)
        |> Map.put("pair_count", length(distances))

      {:error, %{type: :insufficient_data, minimum_count: minimum_count}} ->
        %{
          "status" => "insufficient_data",
          "successful_samples" => length(outputs),
          "minimum_successful_samples" => minimum_count,
          "excluded_incomplete_samples" => excluded_incomplete_samples,
          "pair_count" => 0
        }
    end
  end

  defp latency_summary(samples) do
    samples
    |> Enum.map(&get_in(&1, ["response", "latency_ms"]))
    |> numeric_summary()
  end

  defp numeric_summary([]) do
    %{
      "status" => "insufficient_data",
      "count" => 0,
      "mean" => nil,
      "minimum" => nil,
      "maximum" => nil,
      "sample_standard_deviation" => nil
    }
  end

  defp numeric_summary(values) do
    {:ok, mean} = Statistics.mean(values)

    standard_deviation =
      case Statistics.sample_standard_deviation(values) do
        {:ok, value} -> value
        {:error, %{type: :insufficient_data}} -> nil
      end

    %{
      "status" => "available",
      "count" => length(values),
      "mean" => mean,
      "minimum" => Enum.min(values),
      "maximum" => Enum.max(values),
      "sample_standard_deviation" => standard_deviation
    }
  end

  defp usage_summary(samples) do
    Enum.reduce(
      samples,
      %{"input_tokens" => 0, "output_tokens" => 0},
      fn sample, totals ->
        usage = get_in(sample, ["response", "usage"])

        %{
          "input_tokens" => totals["input_tokens"] + usage["input_tokens"],
          "output_tokens" => totals["output_tokens"] + usage["output_tokens"]
        }
      end
    )
  end

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator
end
