defmodule SilentRegression.SpikeFixtures do
  @moduledoc false

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.Run

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
end
