defmodule SilentRegression.ContractAuthoring.Rescorer do
  @moduledoc """
  Deterministically rescores stored monitor outputs before a successor contract becomes active.
  """

  import Ecto.Query

  alias SilentRegression.Captures.{CaptureObservation, CaptureRun, EvaluationPersistence}

  alias SilentRegression.ContractAuthoring.{
    ContractVersion,
    RescoreSummary
  }

  alias SilentRegression.Repo

  def rescore(%ContractVersion{} = contract_version, predecessor) do
    observations = successful_observations(contract_version.monitor_id)

    with {:ok, counts} <- evaluate_all(observations, contract_version) do
      attrs =
        counts
        |> Map.put(:observation_count, length(observations))
        |> Map.put(
          :interpretation_changed,
          interpretation_changed?(contract_version, predecessor)
        )
        |> Map.put(:rescored_at, DateTime.utc_now())

      %RescoreSummary{}
      |> RescoreSummary.create_changeset(contract_version, predecessor, attrs)
      |> Repo.insert()
    end
  end

  defp successful_observations(monitor_id) do
    CaptureObservation
    |> join(:inner, [observation], run in CaptureRun, on: run.id == observation.capture_run_id)
    |> where(
      [observation, run],
      run.monitor_id == ^monitor_id and observation.status == :succeeded
    )
    |> order_by([observation, run], asc: run.inserted_at, asc: observation.id)
    |> Repo.all()
  end

  defp evaluate_all(observations, contract_version) do
    Enum.reduce_while(
      observations,
      {:ok, %{pass_count: 0, fail_count: 0, evaluator_error_count: 0}},
      fn observation, {:ok, counts} ->
        case EvaluationPersistence.ensure(
               observation,
               contract_version,
               contract_version.evaluator_engine_version
             ) do
          {:ok, %{status: :evaluator_error} = evaluation} ->
            {:halt,
             {:error,
              {:rescore_failed, observation.id, evaluation.error || %{"code" => "unknown"}}}}

          {:ok, evaluation} ->
            key = count_key(evaluation.status)
            {:cont, {:ok, Map.update!(counts, key, &(&1 + 1))}}

          {:error, reason} ->
            {:halt, {:error, {:rescore_failed, observation.id, reason}}}
        end
      end
    )
  end

  defp interpretation_changed?(_contract_version, nil), do: true

  defp interpretation_changed?(contract_version, predecessor) do
    contract_version.contract_fingerprint != predecessor.contract_fingerprint or
      contract_version.evaluator_engine_version != predecessor.evaluator_engine_version
  end

  defp count_key(:pass), do: :pass_count
  defp count_key(:fail), do: :fail_count
end
