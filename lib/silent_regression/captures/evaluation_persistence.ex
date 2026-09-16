defmodule SilentRegression.Captures.EvaluationPersistence do
  @moduledoc """
  Shared immutable persistence boundary for capture evaluation and contract rescoring.

  Callers provide their transaction boundary. Repeating the same observation, contract, and engine
  returns the existing evaluation.
  """

  import Ecto.Query

  alias SilentRegression.Captures.{CaptureEvaluation, CaptureObservation, CaptureRuleResult}
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Contracts
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

    with {:ok, contract} <- Contracts.parse_contract(source),
         {:ok, evaluator_observation} <-
           Contracts.new_observation(%{
             "id" => observation.id,
             "output_text" => observation.output_text
           }),
         {:ok, evaluation} <-
           Contracts.rescore(contract, evaluator_observation,
             evaluator_engine_version: evaluator_engine_version
           ),
         {:ok, persisted} <-
           %CaptureEvaluation{}
           |> CaptureEvaluation.create_changeset(observation, contract_version, %{
             evaluator_engine_version: evaluation.evaluator_engine_version,
             contract_fingerprint: evaluation.contract_fingerprint,
             status: evaluation.status,
             root_rule_id: evaluation.root_rule_id,
             error: evaluation.error,
             evaluated_at: evaluation.evaluated_at
           })
           |> Repo.insert(),
         :ok <- persist_rule_results(persisted, evaluation.rule_results) do
      {:ok, persisted}
    end
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
