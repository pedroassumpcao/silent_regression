defmodule SilentRegression.SpikeFixtures do
  @moduledoc false

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.CaseSet
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
end
