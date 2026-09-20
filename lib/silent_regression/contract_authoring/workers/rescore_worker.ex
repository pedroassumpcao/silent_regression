defmodule SilentRegression.ContractAuthoring.Workers.RescoreWorker do
  @moduledoc """
  Processes one bounded batch from a pinned contract rescore run.
  """

  use Oban.Worker,
    queue: :contract_rescore,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias SilentRegression.ContractAuthoring.Rescorer

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"rescore_run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Rescorer.process_batch(run_id) do
      result when result in [:continue, :activated, :failed, :complete, :discard] ->
        :ok

      {:error, reason} when attempt >= max_attempts ->
        case Rescorer.fail_infrastructure(run_id, reason) do
          {:ok, :ok} -> :ok
          {:error, failure_reason} -> {:error, inspect(failure_reason)}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
