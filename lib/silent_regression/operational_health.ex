defmodule SilentRegression.OperationalHealth do
  @moduledoc """
  Content-free hosted health checks for traffic readiness and operator alerting.

  Traffic readiness checks only database availability. Operational checks are
  separate so backlogs remain visible without removing healthy web capacity.
  """

  import Ecto.Query

  alias Oban.Job
  alias SilentRegression.Captures.{CaptureObservation, ProviderAttempt}
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.Notifications.Delivery
  alias SilentRegression.OperationalHealth.Heartbeat
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.Workspace

  @heartbeat_names [:scheduler_dispatch, :workspace_purge]
  @statuses [:ok, :degraded, :critical]

  def readiness do
    case Repo.query("SELECT 1", [], log: false) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :database_unavailable}
    end
  rescue
    _error -> {:error, :database_unavailable}
  end

  def snapshot(opts \\ []) do
    now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)

    config =
      Keyword.get(
        opts,
        :config,
        Application.fetch_env!(:silent_regression, :operational_health)
      )

    checks = [
      queue_check(now, config),
      scheduler_check(now, config),
      unknown_outcome_check(now),
      notification_check(now, config),
      purge_check(now, config)
    ]

    status = Enum.reduce(checks, :ok, &worse_status(&1.status, &2))

    :telemetry.execute(
      [:silent_regression, :operational_health, :snapshot],
      %{check_count: length(checks)},
      %{status: status}
    )

    %{status: status, checked_at: now, checks: checks}
  rescue
    _error ->
      %{
        status: :critical,
        checked_at: DateTime.utc_now(:second),
        checks: [%{name: :database, status: :critical, measurements: %{available: false}}]
      }
  end

  def record_heartbeat(name, status, opts \\ [])
      when name in @heartbeat_names and status in [:ok, :error] do
    observed_at = Keyword.get(opts, :at, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{name: name, status: status, observed_at: observed_at}

    %Heartbeat{}
    |> Heartbeat.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [status: status, observed_at: observed_at, updated_at: now]],
      conflict_target: [:name]
    )
  end

  defp queue_check(now, config) do
    queues = Keyword.fetch!(config, :queues)
    backlog_limit = Keyword.fetch!(config, :queue_backlog_limit)
    oldest_seconds = Keyword.fetch!(config, :queue_oldest_seconds)
    stale_before = DateTime.add(now, -oldest_seconds, :second)
    recent_before = DateTime.add(now, -86_400, :second)

    backlog =
      Job
      |> where([job], job.queue in ^queues and job.state == "available")
      |> group_by([job], job.queue)
      |> select([job], {job.queue, count(job.id), min(job.scheduled_at)})
      |> Repo.all()

    discarded =
      Job
      |> where(
        [job],
        job.queue in ^queues and job.state == "discarded" and job.discarded_at >= ^recent_before
      )
      |> Repo.aggregate(:count)

    backlog_count =
      Enum.reduce(backlog, 0, fn {_queue, count, _oldest}, total -> total + count end)

    stale_count =
      Enum.count(backlog, fn {_queue, _count, oldest} ->
        oldest && DateTime.before?(oldest, stale_before)
      end)

    status =
      cond do
        discarded > 0 -> :critical
        backlog_count > backlog_limit or stale_count > 0 -> :degraded
        true -> :ok
      end

    %{
      name: :queues,
      status: status,
      measurements: %{
        available: backlog_count,
        stale_queues: stale_count,
        discarded_24h: discarded
      }
    }
  end

  defp scheduler_check(now, config) do
    heartbeat_limit = Keyword.fetch!(config, :scheduler_heartbeat_seconds)
    overdue_seconds = Keyword.fetch!(config, :scheduler_overdue_seconds)
    heartbeat_before = DateTime.add(now, -heartbeat_limit, :second)
    overdue_before = DateTime.add(now, -overdue_seconds, :second)

    heartbeat = Repo.get_by(Heartbeat, name: :scheduler_dispatch)

    heartbeat_fresh? =
      heartbeat && heartbeat.status == :ok &&
        DateTime.compare(heartbeat.observed_at, heartbeat_before) in [:gt, :eq]

    overdue =
      Monitor
      |> where(
        [monitor],
        monitor.state == :active and monitor.cadence in [:daily, :weekly] and
          is_nil(monitor.capacity_wait_reason) and not is_nil(monitor.next_run_at) and
          monitor.next_run_at < ^overdue_before
      )
      |> Repo.aggregate(:count)

    %{
      name: :scheduler,
      status: if(heartbeat_fresh? and overdue == 0, do: :ok, else: :critical),
      measurements: %{heartbeat_fresh: !!heartbeat_fresh?, overdue_monitors: overdue}
    }
  end

  defp unknown_outcome_check(now) do
    observations =
      CaptureObservation
      |> where([observation], observation.status == :unknown)
      |> Repo.aggregate(:count)

    attempts =
      ProviderAttempt
      |> where([attempt], attempt.status == :unknown)
      |> Repo.aggregate(:count)

    expired_started =
      ProviderAttempt
      |> where(
        [attempt],
        attempt.status == :started and attempt.lease_expires_at < ^now
      )
      |> Repo.aggregate(:count)

    total = observations + attempts + expired_started

    %{
      name: :provider_outcomes,
      status: if(total == 0, do: :ok, else: :critical),
      measurements: %{
        unknown_observations: observations,
        unknown_attempts: attempts,
        expired_started_attempts: expired_started
      }
    }
  end

  defp notification_check(now, config) do
    stale_before =
      DateTime.add(now, -Keyword.fetch!(config, :notification_pending_seconds), :second)

    failed =
      Delivery
      |> where([delivery], delivery.status == :failed)
      |> Repo.aggregate(:count)

    stale_pending =
      Delivery
      |> where(
        [delivery],
        delivery.status == :pending and delivery.inserted_at < ^stale_before
      )
      |> Repo.aggregate(:count)

    status = if failed + stale_pending == 0, do: :ok, else: :degraded

    %{
      name: :notifications,
      status: status,
      measurements: %{failed: failed, stale_pending: stale_pending}
    }
  end

  defp purge_check(now, config) do
    overdue_before = DateTime.add(now, -Keyword.fetch!(config, :purge_overdue_seconds), :second)
    sla_before = DateTime.add(now, -Keyword.fetch!(config, :explicit_purge_sla_seconds), :second)

    overdue =
      Workspace
      |> where(
        [workspace],
        workspace.status == :closed and not is_nil(workspace.purge_after) and
          workspace.purge_after < ^overdue_before
      )
      |> Repo.aggregate(:count)

    sla_breaches =
      Workspace
      |> where(
        [workspace],
        workspace.status == :closed and not is_nil(workspace.deletion_requested_at) and
          workspace.deletion_requested_at < ^sla_before
      )
      |> Repo.aggregate(:count)

    purge_heartbeat = Repo.get_by(Heartbeat, name: :workspace_purge)
    worker_error? = purge_heartbeat && purge_heartbeat.status == :error

    status =
      cond do
        sla_breaches > 0 or worker_error? -> :critical
        overdue > 0 -> :degraded
        true -> :ok
      end

    %{
      name: :purge,
      status: status,
      measurements: %{
        overdue: overdue,
        explicit_sla_breaches: sla_breaches,
        last_worker_error: !!worker_error?
      }
    }
  end

  defp worse_status(status, current) do
    if status_rank(status) > status_rank(current), do: status, else: current
  end

  defp status_rank(status), do: Enum.find_index(@statuses, &(&1 == status))
end
