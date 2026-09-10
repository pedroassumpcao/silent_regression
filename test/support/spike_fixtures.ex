defmodule SilentRegression.SpikeFixtures do
  @moduledoc false

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.Calibration
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.RunAnalysis

  def case_definition(overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          id: "rag_case",
          version: 1,
          category: "rag",
          description: "A frozen RAG case",
          system_prompt: "Use only the supplied context.",
          context: "Source A says the launch is on Tuesday.",
          question: "When is the launch?",
          response_format: "Answer in one sentence.",
          fingerprint: String.duplicate("a", 64),
          checks: [%{"type" => "required_phrase", "value" => "Tuesday"}],
          tags: ["rag", "grounded"]
        },
        overrides
      )

    {:ok, case_definition} = Case.new(attributes)
    case_definition
  end

  def response(overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          provider: "openai",
          requested_model: "model-requested",
          returned_model: "model-returned",
          output_text: "The launch is on Tuesday.",
          request_id: "response-123",
          usage: %{"input_tokens" => 42, "output_tokens" => 7},
          latency_ms: 120,
          finish_reason: "stop",
          captured_at: ~U[2026-09-07 12:00:01Z],
          raw: %{"id" => "response-123"},
          attempts: 1
        },
        overrides
      )

    {:ok, response} = Response.new(attributes)
    response
  end

  def run(overrides \\ %{}) do
    case_definition = case_definition()
    response = response()

    attributes =
      Map.merge(
        %{
          schema_version: Run.schema_version(),
          run_id: "run-20260907-120000",
          label: "pilot baseline",
          condition: "baseline",
          started_at: ~U[2026-09-07 12:00:00Z],
          completed_at: ~U[2026-09-07 12:00:02Z],
          git_revision: "abc1234",
          provider: "openai",
          request_config: %{
            "model" => "model-requested",
            "max_output_tokens" => 128
          },
          cases: [case_definition],
          samples: [
            %{
              "case_id" => case_definition.id,
              "sample_index" => 0,
              "status" => "ok",
              "response" => Response.to_map(response)
            }
          ],
          metrics: %{},
          totals: %{"attempts" => 1, "successful_samples" => 1, "failed_samples" => 0}
        },
        overrides
      )

    {:ok, run} = Run.new(attributes)
    run
  end

  def analyzed_run(overrides \\ %{}) do
    {:ok, default_case} = CaseSet.fetch("rag_open_synthesis")
    case_definition = Map.get(overrides, :case_definition, default_case)
    outputs = Map.get(overrides, :outputs, ["red apple", "apple red"])
    requested_model = Map.get(overrides, :requested_model, "fake-model")
    returned_model = Map.get(overrides, :returned_model, "fake-model")

    finish_reasons =
      Map.get(overrides, :finish_reasons, List.duplicate("completed", length(outputs)))

    samples =
      outputs
      |> Enum.zip(finish_reasons)
      |> Enum.with_index()
      |> Enum.map(fn {{output, finish_reason}, index} ->
        response =
          response(%{
            provider: Map.get(overrides, :provider, "fake"),
            requested_model: requested_model,
            returned_model: returned_model,
            output_text: output,
            request_id: "response-#{Map.get(overrides, :run_id, "run")}-#{index}",
            finish_reason: finish_reason,
            raw: %{"id" => "response-#{Map.get(overrides, :run_id, "run")}-#{index}"}
          })

        %{
          "case_id" => case_definition.id,
          "case_fingerprint" => case_definition.fingerprint,
          "sample_index" => index,
          "status" => "ok",
          "attempts" => 1,
          "response" => Response.to_map(response)
        }
      end)

    {:ok, %{"samples" => scored_samples, "metrics" => metrics}} =
      RunAnalysis.analyze([case_definition], samples)

    request_config =
      Map.merge(
        %{
          "api_endpoint" => "https://fake.invalid/v1/completions",
          "api_version" => "v1",
          "http_method" => "POST",
          "model" => requested_model,
          "max_output_tokens" => 512,
          "max_retries" => 0,
          "samples_per_case" => length(outputs),
          "model_availability" => %{
            "provider" => Map.get(overrides, :provider, "fake"),
            "requested_model" => requested_model,
            "returned_model" => requested_model,
            "attempts" => 1
          }
        },
        Map.get(overrides, :request_config, %{})
      )

    totals = %{
      "planned_samples" => length(outputs),
      "planned_calls" => length(outputs) + 1,
      "maximum_calls" => length(outputs) + 1,
      "actual_calls" => length(outputs) + 1,
      "availability_calls" => 1,
      "generation_calls" => length(outputs),
      "successful_samples" => length(outputs),
      "failed_samples" => 0,
      "completed_samples" => Enum.count(scored_samples, &get_in(&1, ["completion", "passed"])),
      "incomplete_samples" =>
        Enum.count(scored_samples, &(get_in(&1, ["completion", "status"]) == "incomplete")),
      "unknown_completion_samples" =>
        Enum.count(scored_samples, &(get_in(&1, ["completion", "status"]) == "unknown")),
      "quality_passed_samples" => Enum.count(scored_samples, &get_in(&1, ["quality", "passed"])),
      "quality_failed_samples" =>
        Enum.count(scored_samples, &(get_in(&1, ["quality", "passed"]) == false)),
      "latency_ms" => length(outputs) * 120,
      "input_tokens" => length(outputs) * 42,
      "output_tokens" => length(outputs) * 7,
      "returned_models" => %{returned_model => length(outputs)}
    }

    {:ok, run} =
      Run.new(%{
        run_id: Map.get(overrides, :run_id, "analyzed-baseline"),
        label: Map.get(overrides, :label, "analyzed run"),
        condition: Map.get(overrides, :condition, "baseline"),
        started_at: Map.get(overrides, :started_at, ~U[2026-09-07 12:00:00Z]),
        completed_at: Map.get(overrides, :completed_at, ~U[2026-09-07 12:00:02Z]),
        git_revision: Map.get(overrides, :git_revision, "abc1234"),
        provider: Map.get(overrides, :provider, "fake"),
        request_config: request_config,
        cases: [case_definition],
        samples: scored_samples,
        metrics: metrics,
        totals: totals
      })

    run
  end

  def analyzed_case_set_run(overrides \\ %{}) do
    cases = CaseSet.all()
    sample_size = Map.get(overrides, :sample_size, 20)
    requested_model = Map.get(overrides, :requested_model, "fake-model")
    returned_model = Map.get(overrides, :returned_model, "fake-model")
    provider = Map.get(overrides, :provider, "fake")
    run_id = Map.get(overrides, :run_id, "case-set-run")

    samples =
      Enum.flat_map(cases, fn case_definition ->
        output =
          Map.get(
            Map.get(overrides, :outputs_by_case, %{}),
            case_definition.id,
            valid_output(case_definition.id)
          )

        Enum.map(0..(sample_size - 1), fn index ->
          response =
            response(%{
              provider: provider,
              requested_model: requested_model,
              returned_model: returned_model,
              output_text: output,
              request_id: "response-#{run_id}-#{case_definition.id}-#{index}",
              finish_reason: "completed",
              raw: %{"source" => "test"}
            })

          %{
            "case_id" => case_definition.id,
            "case_fingerprint" => case_definition.fingerprint,
            "sample_index" => index,
            "status" => "ok",
            "attempts" => 1,
            "response" => Response.to_map(response)
          }
        end)
      end)

    {:ok, %{"samples" => scored_samples, "metrics" => metrics}} =
      RunAnalysis.analyze(cases, samples)

    request_config = %{
      "api_endpoint" => "https://fake.invalid/v1/completions",
      "api_version" => "v1",
      "http_method" => "POST",
      "model" => requested_model,
      "max_output_tokens" => 512,
      "max_retries" => 0,
      "samples_per_case" => sample_size,
      "model_availability" => %{
        "provider" => provider,
        "requested_model" => requested_model,
        "returned_model" => returned_model,
        "attempts" => 1
      }
    }

    totals = %{
      "planned_samples" => length(scored_samples),
      "planned_calls" => length(scored_samples) + 1,
      "maximum_calls" => length(scored_samples) + 1,
      "actual_calls" => length(scored_samples) + 1,
      "availability_calls" => 1,
      "generation_calls" => length(scored_samples),
      "successful_samples" => length(scored_samples),
      "failed_samples" => 0,
      "completed_samples" => length(scored_samples),
      "incomplete_samples" => 0,
      "unknown_completion_samples" => 0,
      "quality_passed_samples" => Enum.count(scored_samples, &get_in(&1, ["quality", "passed"])),
      "quality_failed_samples" =>
        Enum.count(scored_samples, &(get_in(&1, ["quality", "passed"]) == false)),
      "latency_ms" => length(scored_samples) * 120,
      "input_tokens" => length(scored_samples) * 42,
      "output_tokens" => length(scored_samples) * 7,
      "returned_models" => %{returned_model => length(scored_samples)}
    }

    {:ok, run} =
      Run.new(%{
        run_id: run_id,
        label: Map.get(overrides, :label, "case set run"),
        condition: Map.get(overrides, :condition, "baseline"),
        started_at: ~U[2026-09-07 12:00:00Z],
        completed_at: ~U[2026-09-07 12:00:02Z],
        git_revision: "abc1234",
        provider: provider,
        request_config: request_config,
        cases: cases,
        samples: scored_samples,
        metrics: metrics,
        totals: totals
      })

    run
  end

  def calibration_for(baseline, overrides \\ %{}) do
    control_size = Map.get(overrides, :control_size, 20)

    thresholds =
      Enum.map(baseline.cases, fn case_definition ->
        %{
          "case_id" => case_definition.id,
          "case_fingerprint" => case_definition.fingerprint,
          "threshold" => Map.get(overrides, :threshold, 0.0),
          "null_energies" => [0.0, 0.0]
        }
      end)

    {:ok, calibration} =
      Calibration.new(%{
        calibration_id: Map.get(overrides, :calibration_id, "frozen-calibration"),
        created_at: ~U[2026-09-07 13:00:00Z],
        git_revision: "abc1234",
        baseline_run_id: baseline.run_id,
        control_run_ids: ["calibration-source"],
        source_run_ids: [baseline.run_id, "calibration-source"],
        provenance: Comparison.provenance(baseline),
        settings: %{
          "seed" => 91,
          "iterations" => 20,
          "quantile" => 0.95,
          "adjusted_p_alpha" => 0.05,
          "baseline_group_size" => baseline.request_config["samples_per_case"],
          "control_group_size" => control_size
        },
        thresholds: thresholds
      })

    calibration
  end

  defp valid_output("rag_structured_extract") do
    ~s({"project_name":"Meridian Lantern","launch_date":"2042-11-18","city":"Bellweather Harbor","budget_usd":480000,"source_ids":["brief-7","finance-2"]})
  end

  defp valid_output("rag_answer_with_citations") do
    "Tours run every Wednesday and Friday at 10:30 a.m. for 75 minutes " <>
      "[tour-schedule], and reservations require 24 hours notice [booking-policy]."
  end

  defp valid_output("rag_abstain_when_unsupported") do
    "The paid parental leave duration cannot be determined from [benefits-guide]."
  end

  defp valid_output("rag_open_synthesis") do
    "The 12-ferry electric fleet targets a 19-minute crossing by 2044 [transit-plan]. " <>
      "Phase one funds Dock 3 and six ferries; six need later funding [phase-one-budget].\n\n" <>
      "From March through July, the 12-knot limit and pile-driving ban protect nesting " <>
      "islands while constraining deployment [habitat-rules]."
  end
end
