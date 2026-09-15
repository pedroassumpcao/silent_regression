defmodule SilentRegression.Captures.Workers.ObservationWorker do
  @moduledoc """
  Executes at most one provider request per invocation for a planned observation.
  """

  use Oban.Worker,
    queue: :capture,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias SilentRegression.Captures

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"capture_run_id" => capture_run_id, "observation_id" => observation_id}
      }) do
    case Captures.execute_observation(capture_run_id, observation_id) do
      :ok -> :ok
      {:retry, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
