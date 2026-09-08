defmodule SilentRegression.Spike.RunAnalysisTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.RunAnalysis
  alias SilentRegression.SpikeFixtures

  test "scores ordered samples and reports deterministic, lexical, latency, and usage metrics" do
    {:ok, case_definition} = CaseSet.fetch("rag_answer_with_citations")

    samples = [
      sample(
        case_definition,
        0,
        "Tours run Wednesday and Friday at 10:30 a.m. and last 75 minutes " <>
          "[tour-schedule]. Book 24 hours ahead [booking-policy].",
        50,
        10,
        5
      ),
      sample(
        case_definition,
        1,
        "Every Wednesday and Friday, the 75-minute tours start at 10:30 [tour-schedule].",
        100,
        20,
        8
      )
    ]

    assert {:ok, analysis} = RunAnalysis.analyze([case_definition], samples)
    assert Enum.map(analysis["samples"], & &1["sample_index"]) == [0, 1]
    assert Enum.map(analysis["samples"], & &1["deterministic"]["all_passed"]) == [true, false]

    [case_metrics] = analysis["metrics"]["by_case"]
    assert case_metrics["deterministic"]["sample_pass_rate"] == 0.5
    assert case_metrics["deterministic"]["passed_samples"] == 1
    assert case_metrics["deterministic"]["evaluated_samples"] == 2
    assert case_metrics["deterministic"]["check_pass_rate"] < 1.0

    assert case_metrics["completion"] == %{
             "completed_samples" => 2,
             "completion_rate" => 1.0,
             "evaluated_samples" => 2,
             "finish_reasons" => %{"stop" => 2},
             "incomplete_samples" => 0,
             "unknown_samples" => 0
           }

    assert case_metrics["quality"] == %{
             "evaluated_samples" => 2,
             "failed_samples" => 1,
             "failure_reasons" => %{"deterministic_checks_failed" => 1},
             "pass_rate" => 0.5,
             "passed_samples" => 1
           }

    assert case_metrics["within_distance"]["pair_count"] == 1
    assert case_metrics["within_distance"]["excluded_incomplete_samples"] == 0
    assert case_metrics["within_distance"]["mean"] > 0.0
    assert case_metrics["within_distance"]["sample_standard_deviation"] == nil
    assert case_metrics["latency_ms"]["mean"] == 75.0
    assert_in_delta case_metrics["latency_ms"]["sample_standard_deviation"], 35.3553, 0.0001
    assert case_metrics["usage"] == %{"input_tokens" => 30, "output_tokens" => 13}

    assert RunAnalysis.success_totals(analysis["samples"]) == %{
             "latency_ms" => 150,
             "input_tokens" => 30,
             "output_tokens" => 13,
             "returned_models" => %{"fake-model-snapshot" => 2}
           }
  end

  test "marks incomplete responses as quality failures and excludes them from drift metrics" do
    {:ok, case_definition} = CaseSet.fetch("rag_answer_with_citations")

    valid_output =
      "Tours run Wednesday and Friday at 10:30 a.m. and last 75 minutes " <>
        "[tour-schedule]. Book 24 hours ahead [booking-policy]."

    completed = sample(case_definition, 0, valid_output, 50, 10, 5)

    incomplete =
      case_definition
      |> sample(1, valid_output, 75, 10, 6)
      |> put_in(["response", "finish_reason"], "incomplete:max_output_tokens")

    assert {:ok, analysis} = RunAnalysis.analyze([case_definition], [completed, incomplete])
    [completed_sample, incomplete_sample] = analysis["samples"]

    assert completed_sample["quality"]["passed"]
    assert incomplete_sample["deterministic"]["all_passed"]
    refute incomplete_sample["completion"]["passed"]
    assert incomplete_sample["completion"]["status"] == "incomplete"
    assert incomplete_sample["quality"]["reason"] == "response_incomplete"
    refute incomplete_sample["quality"]["passed"]

    [case_metrics] = analysis["metrics"]["by_case"]
    assert case_metrics["completion"]["completed_samples"] == 1
    assert case_metrics["completion"]["incomplete_samples"] == 1
    assert case_metrics["completion"]["completion_rate"] == 0.5
    assert case_metrics["quality"]["passed_samples"] == 1
    assert case_metrics["quality"]["failed_samples"] == 1
    assert case_metrics["quality"]["failure_reasons"] == %{"response_incomplete" => 1}
    assert case_metrics["within_distance"]["successful_samples"] == 1
    assert case_metrics["within_distance"]["excluded_incomplete_samples"] == 1
    assert case_metrics["within_distance"]["status"] == "insufficient_data"

    assert RunAnalysis.success_totals(analysis["samples"]) == %{
             "latency_ms" => 125,
             "input_tokens" => 20,
             "output_tokens" => 11,
             "returned_models" => %{"fake-model-snapshot" => 2}
           }
  end

  defp sample(case_definition, sample_index, output_text, latency_ms, input_tokens, output_tokens) do
    response =
      SpikeFixtures.response(%{
        provider: "fake",
        requested_model: "fake-model",
        returned_model: "fake-model-snapshot",
        output_text: output_text,
        usage: %{"input_tokens" => input_tokens, "output_tokens" => output_tokens},
        latency_ms: latency_ms
      })

    %{
      "case_id" => case_definition.id,
      "case_fingerprint" => case_definition.fingerprint,
      "sample_index" => sample_index,
      "status" => "ok",
      "attempts" => response.attempts,
      "response" => Response.to_map(response)
    }
  end
end
