defmodule SilentRegression.PilotPolicies do
  @moduledoc """
  Persists, presents, and atomically enforces private-alpha run and call limits.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.PilotPolicies.Policy
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @active_run_statuses [:planned, :queued, :running]
  @defaults %{daily_run_limit: 20, daily_call_limit: 200, per_run_call_limit: 200}

  def usage(scope, at \\ DateTime.utc_now())

  def usage(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        at
      ) do
    policy = ensure_policy!(workspace_id)
    usage = usage_for_workspace(workspace_id, at)

    %{
      daily_run_limit: policy.daily_run_limit,
      daily_call_limit: policy.daily_call_limit,
      per_run_call_limit: policy.per_run_call_limit,
      runs_today: usage.runs,
      committed_calls_today: usage.calls,
      remaining_runs_today: max(policy.daily_run_limit - usage.runs, 0),
      remaining_calls_today: max(policy.daily_call_limit - usage.calls, 0),
      resets_at: next_utc_day(at),
      allowed_models: Application.fetch_env!(:silent_regression, :monitor_domain)[:allowed_models]
    }
  end

  def usage(%Scope{}, _at), do: {:error, :workspace_required}

  @doc false
  def check_capacity(workspace_id, maximum_calls, at \\ DateTime.utc_now()) do
    policy = ensure_policy!(workspace_id)
    ensure_capacity(policy, usage_for_workspace(workspace_id, at), maximum_calls)
  end

  @doc false
  def authorize_new_run(workspace_id, maximum_calls, at \\ DateTime.utc_now()) do
    policy = locked_policy!(workspace_id)
    ensure_capacity(policy, usage_for_workspace(workspace_id, at), maximum_calls)
  end

  @doc false
  def update_limits!(workspace_id, attrs) do
    workspace_id
    |> ensure_policy!()
    |> Policy.create_changeset(workspace_id, attrs)
    |> Repo.update!()
  end

  defp ensure_capacity(policy, usage, maximum_calls) do
    cond do
      maximum_calls > policy.per_run_call_limit -> {:error, :per_run_call_limit}
      usage.runs + 1 > policy.daily_run_limit -> {:error, :workspace_run_limit}
      usage.calls + maximum_calls > policy.daily_call_limit -> {:error, :workspace_call_limit}
      true -> :ok
    end
  end

  defp usage_for_workspace(workspace_id, at) do
    day_start = DateTime.new!(DateTime.to_date(at), ~T[00:00:00], "Etc/UTC")

    base =
      from run in CaptureRun,
        where:
          run.workspace_id == ^workspace_id and
            (run.inserted_at >= ^day_start or run.status in ^@active_run_statuses or
               run.completed_at >= ^day_start)

    %{
      runs: Repo.aggregate(base, :count),
      calls: Repo.one(from run in base, select: coalesce(sum(run.maximum_call_count), 0))
    }
  end

  defp ensure_policy!(workspace_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Policy,
      [
        Map.merge(@defaults, %{
          id: Ecto.UUID.generate(),
          workspace_id: workspace_id,
          inserted_at: now,
          updated_at: now
        })
      ],
      on_conflict: :nothing,
      conflict_target: [:workspace_id]
    )

    Repo.get_by!(Policy, workspace_id: workspace_id)
  end

  defp locked_policy!(workspace_id) do
    _policy = ensure_policy!(workspace_id)

    Policy
    |> where([policy], policy.workspace_id == ^workspace_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp next_utc_day(at) do
    at
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
