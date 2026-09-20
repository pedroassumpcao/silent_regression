defmodule SilentRegression.WorkspaceLifecycle.Workers.PurgeWorker do
  @moduledoc """
  Periodically purges a bounded batch of workspaces whose persisted deadline is due.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 840,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias SilentRegression.{OperationalHealth, WorkspaceLifecycle}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case WorkspaceLifecycle.purge_due_workspaces() do
      {:ok, _summary} ->
        {:ok, _heartbeat} = OperationalHealth.record_heartbeat(:workspace_purge, :ok)
        :ok

      {:error, summary} ->
        {:ok, _heartbeat} = OperationalHealth.record_heartbeat(:workspace_purge, :error)
        {:error, "#{summary.failed} due workspace purge(s) failed"}
    end
  end
end
