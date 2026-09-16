defmodule SilentRegression.MonitorOperations.Workers.DispatcherWorker do
  @moduledoc """
  Wakes the database-backed monitor scheduler. Tenant cadence remains durable monitor state.
  """

  use Oban.Worker,
    queue: :scheduler,
    max_attempts: 1,
    unique: [period: 55, fields: [:worker], states: [:available, :scheduled, :executing]]

  alias SilentRegression.MonitorOperations

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    with {:ok, _sweep} <- MonitorOperations.sweep_ineligible(now),
         {:ok, _dispatch} <- MonitorOperations.dispatch_due(now) do
      :ok
    end
  end
end
