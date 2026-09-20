defmodule SilentRegression.GuidedDemo do
  @moduledoc """
  A sealed, credential-free scenario evaluated by the production deterministic engines.

  The scenario is deliberately read-only. It demonstrates the product's evidence boundaries without
  creating a monitor, storing customer content, or making a provider call.
  """

  alias SilentRegression.CaseExpectations
  alias SilentRegression.Contracts
  alias SilentRegression.Contracts.{Evaluation, RuleResult}
  alias SilentRegression.Monitors.Fingerprint

  @scenario_version "credential-free-demo-v1"
  @evaluated_at ~U[2026-09-20 00:00:00Z]

  @request %{
    "provider" => "local_demo",
    "requested_model" => "sealed-fixture-v1",
    "body" => %{
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            "Route each support request. Return exactly one label: billing or technical."
        },
        %{
          "role" => "user",
          "content" => "I was charged twice for the same invoice."
        }
      ],
      "temperature" => 0,
      "max_output_tokens" => 8
    }
  }

  @contract_source %{
    "schema_version" => 1,
    "contract_id" => "demo-routing-contract",
    "contract_version" => 1,
    "monitor_id" => "demo-routing-monitor",
    "root" => %{
      "id" => "routing_contract",
      "type" => "all",
      "rules" => [
        %{
          "id" => "allowed_route",
          "type" => "classification",
          "allowed_values" => ["billing", "technical"]
        },
        %{
          "id" => "single_label",
          "type" => "length",
          "severity" => "warning",
          "unit" => "words",
          "minimum" => 1,
          "maximum" => 1
        }
      ]
    }
  }

  @expectation %{
    "checks" => [
      %{"id" => "expected_route", "type" => "label", "allowed_values" => ["billing"]}
    ]
  }

  @reference_output "billing"
  @regression_output "technical"

  @sealed_content %{
    "scenario_version" => @scenario_version,
    "request" => @request,
    "contract" => @contract_source,
    "case_expectation" => @expectation,
    "reference_output" => @reference_output,
    "recurring_output" => @regression_output
  }

  def scenario do
    {:ok, contract} = Contracts.parse_contract(@contract_source)
    {:ok, normalized_expectation} = CaseExpectations.normalize(nil, @expectation)

    reference =
      evaluate(
        "demo-reference-observation",
        @reference_output,
        contract,
        normalized_expectation
      )

    recurring =
      evaluate(
        "demo-recurring-observation",
        @regression_output,
        contract,
        normalized_expectation
      )

    %{
      scenario_version: @scenario_version,
      sealed_fingerprint: Fingerprint.digest(@sealed_content),
      provider_calls: 0,
      request: @request,
      contract: %{
        fingerprint: contract.fingerprint,
        root: contract.root,
        explanation:
          "Every output must be one of two allowed routing labels and contain exactly one word."
      },
      case_expectation: %{
        schema_version: normalized_expectation.schema_version,
        fingerprint: normalized_expectation.fingerprint,
        payload: normalized_expectation.expectation,
        explanation:
          "For this duplicate-charge case, the correct allowed label is specifically billing."
      },
      reference: Map.put(reference, :role, "reviewed_reference"),
      recurring: Map.put(recurring, :role, "recurring_sample"),
      incident: %{
        severity: "critical",
        signature: "case_expectation_failure:expected_route:duplicate_charge",
        explanation:
          "The output still satisfies the broad routing contract, but violates the reviewed case-specific expectation. This is the silent regression the product surfaces."
      }
    }
  end

  defp evaluate(observation_id, output, contract, expectation) do
    {:ok, observation} =
      Contracts.new_observation(%{"id" => observation_id, "output_text" => output})

    {:ok, contract_evaluation} =
      Contracts.evaluate(contract, observation,
        evaluation_id: "#{observation_id}-evaluation",
        evaluated_at: @evaluated_at
      )

    case_evaluation =
      CaseExpectations.evaluate(
        expectation.schema_version,
        expectation.expectation,
        expectation.fingerprint,
        output
      )

    %{
      observation_id: observation_id,
      output: output,
      contract_status: Atom.to_string(contract_evaluation.status),
      contract_results: Enum.map(contract_evaluation.rule_results, &rule_result/1),
      case_expectation_status: Atom.to_string(case_evaluation.status),
      case_expectation_results: Enum.map(case_evaluation.results, &expectation_result/1),
      overall_status: overall_status(contract_evaluation, case_evaluation),
      evaluator_engine_version: contract_evaluation.evaluator_engine_version,
      evaluated_at: DateTime.to_iso8601(contract_evaluation.evaluated_at)
    }
  end

  defp overall_status(%Evaluation{status: :pass}, %{status: :pass}), do: "pass"
  defp overall_status(%Evaluation{status: :evaluator_error}, _case), do: "evaluator_error"
  defp overall_status(_contract, %{status: :evaluator_error}), do: "evaluator_error"
  defp overall_status(_contract, _case), do: "fail"

  defp rule_result(%RuleResult{} = result) do
    result
    |> RuleResult.to_map()
    |> Map.take(["rule_id", "rule_type", "severity", "status", "code", "explanation"])
  end

  defp expectation_result(result) do
    %{
      check_id: result.check_id,
      check_type: result.check_type,
      status: Atom.to_string(result.status),
      code: result.code,
      explanation: result.explanation
    }
  end
end
