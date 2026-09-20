defmodule SilentRegression.Captures.EvaluationPersistence do
  @moduledoc """
  Shared immutable persistence boundary for capture evaluation and contract rescoring.

  Callers provide their transaction boundary. Repeating the same observation, contract, and engine
  returns the existing evaluation.
  """

  import Ecto.Query

  alias SilentRegression.CaseExpectations
  alias SilentRegression.Captures.{CaptureEvaluation, CaptureObservation, CaptureRuleResult}
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Contracts
  alias SilentRegression.Monitors.CaseVersion
  alias SilentRegression.Repo

  def ensure(
        %CaptureObservation{} = observation,
        %ContractVersion{} = contract_version,
        evaluator_engine_version
      )
      when is_binary(evaluator_engine_version) do
    case existing(observation.id, contract_version.id, evaluator_engine_version) do
      %CaptureEvaluation{} = evaluation -> {:ok, evaluation}
      nil -> persist(observation, contract_version, evaluator_engine_version)
    end
  end

  defp persist(observation, contract_version, evaluator_engine_version) do
    source = %{
      "schema_version" => contract_version.schema_version,
      "contract_id" => contract_version.id,
      "contract_version" => contract_version.version,
      "monitor_id" => contract_version.monitor_id,
      "root" => contract_version.root
    }

    with %CaseVersion{} = case_version <- Repo.get(CaseVersion, observation.case_version_id),
         {:ok, contract} <- Contracts.parse_contract(source),
         {:ok, evaluator_observation} <-
           Contracts.new_observation(%{
             "id" => observation.id,
             "output_text" => observation.output_text
           }),
         {:ok, evaluation} <-
           Contracts.rescore(contract, evaluator_observation,
             evaluator_engine_version: evaluator_engine_version
           ),
         expectation_evaluation <- evaluate_expectation(case_version, observation.output_text),
         status <- combined_status(evaluation.status, expectation_evaluation.status),
         error <- combined_error(evaluation.error, expectation_evaluation.error),
         {:ok, persisted} <-
           %CaptureEvaluation{}
           |> CaptureEvaluation.create_changeset(observation, contract_version, %{
             evaluator_engine_version: evaluation.evaluator_engine_version,
             contract_fingerprint: evaluation.contract_fingerprint,
             status: status,
             contract_status: evaluation.status,
             case_expectation_schema_version: expectation_evaluation.schema_version,
             case_expectation_fingerprint: expectation_evaluation.fingerprint,
             case_expectation_status: expectation_evaluation.status,
             case_expectation_results:
               serialize_expectation_results(expectation_evaluation.results),
             case_expectation_error: expectation_evaluation.error,
             root_rule_id: evaluation.root_rule_id,
             error: error,
             evaluated_at: evaluation.evaluated_at
           })
           |> Repo.insert(),
         :ok <- persist_rule_results(persisted, evaluation.rule_results) do
      {:ok, persisted}
    else
      nil -> {:error, :case_version_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate_expectation(case_version, output) do
    CaseExpectations.evaluate(
      case_version.expectation_schema_version,
      case_version.expectation,
      case_version.expectation_fingerprint,
      output
    )
  end

  defp combined_status(:evaluator_error, _expectation_status), do: :evaluator_error
  defp combined_status(_contract_status, :evaluator_error), do: :evaluator_error
  defp combined_status(:fail, _expectation_status), do: :fail
  defp combined_status(_contract_status, :fail), do: :fail

  defp combined_status(:pass, expectation_status)
       when expectation_status in [:not_configured, :pass],
       do: :pass

  defp combined_error(nil, nil), do: nil

  defp combined_error(contract_error, expectation_error) do
    %{
      "code" => "deterministic_evaluator_error",
      "message" => "At least one deterministic evaluation layer could not complete safely.",
      "contract" => contract_error,
      "case_expectation" => expectation_error
    }
  end

  defp serialize_expectation_results(results) do
    %{
      "checks" =>
        Enum.map(results, fn result ->
          %{
            "check_id" => result.check_id,
            "check_type" => result.check_type,
            "status" => Atom.to_string(result.status),
            "code" => result.code,
            "explanation" => result.explanation,
            "evidence" => result.evidence
          }
        end)
    }
  end

  defp persist_rule_results(evaluation, rule_results) do
    rule_results
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {result, position}, :ok ->
      attrs = result |> Map.from_struct() |> Map.put(:position, position)

      case %CaptureRuleResult{}
           |> CaptureRuleResult.create_changeset(evaluation, attrs)
           |> Repo.insert() do
        {:ok, _result} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp existing(observation_id, contract_version_id, evaluator_engine_version) do
    CaptureEvaluation
    |> where(
      [evaluation],
      evaluation.capture_observation_id == ^observation_id and
        evaluation.contract_version_id == ^contract_version_id and
        evaluation.evaluator_engine_version == ^evaluator_engine_version
    )
    |> Repo.one()
  end
end
