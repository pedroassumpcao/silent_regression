defmodule SilentRegression.MonitorOperations do
  @moduledoc """
  Owner-controlled monitor scheduling and workspace-scoped operational state.

  Tenant schedules are durable monitor state. Every spend-producing path is serialized through
  workspace and monitor locks, then delegated to the capture pipeline.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.{Audit, Baselines, Captures, ProductAnalytics}
  alias SilentRegression.Captures.{CaptureObservation, CaptureRun}
  alias SilentRegression.MonitorOperations.Schedule
  alias SilentRegression.Monitors.{CaseVersion, Monitor, MonitorVersion}
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.RunResults
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @active_run_statuses [:planned, :queued, :running]
  @terminal_run_statuses [:succeeded, :partial_failed, :failed, :cancelled, :needs_review]

  def get_state(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}} = scope,
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Monitor{} = monitor <- load_monitor(workspace_id, monitor_id) do
      monitor = Repo.preload(monitor, [:active_version, :schedule_updated_by_user])
      last_run = last_run(workspace_id, monitor.id)

      {:ok,
       %{
         monitor: monitor,
         last_run: last_run,
         unresolved_alerts: unresolved_alert_count(scope, monitor.id),
         approved_baseline?: Baselines.compatible_approved?(scope, monitor.id),
         maximum_call_count: maximum_call_count(monitor),
         workspace_call_limit: operations_config(:daily_workspace_call_limit),
         workspace_committed_calls_today:
           workspace_committed_calls_today(workspace_id, DateTime.utc_now()),
         can_manage?: scope.membership.role == :owner
       }}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_state(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def configure(scope, monitor_id, attrs, options \\ [])

  def configure(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        monitor_id,
        attrs,
        options
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, cadence} <- Schedule.cast(value(attrs, :cadence)) do
      at = operation_time(options)

      with_locked_monitor(workspace_id, monitor_id, fn monitor ->
        with :ok <- ensure_configurable_state(monitor),
             {:ok, maximum_calls} <- run_maximum_call_count(monitor),
             :ok <- ensure_eligible(scope, monitor, maximum_calls, at),
             {:ok, updated} <-
               monitor
               |> Monitor.schedule_changeset(user, %{
                 state: :active,
                 state_changed_at: state_time(at),
                 cadence: cadence,
                 next_run_at: Schedule.first_run_at(cadence, at),
                 pause_reason: nil,
                 schedule_updated_at: at
               })
               |> Repo.update() do
          record_event!(updated, user.id, "monitor.schedule_configured", at, %{
            "cadence" => Atom.to_string(cadence),
            "next_run_at" => iso8601(updated.next_run_at)
          })

          record_schedule_activation!(scope, updated, "configured")

          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def configure(%Scope{}, _monitor_id, _attrs, _options), do: {:error, :owner_required}

  def run_now(scope, monitor_id, options \\ [])

  def run_now(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        monitor_id,
        options
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      at = operation_time(options)

      with_locked_monitor(workspace_id, monitor_id, fn monitor ->
        with :ok <- ensure_active(monitor),
             {:ok, maximum_calls} <- run_maximum_call_count(monitor),
             :ok <- ensure_eligible(scope, monitor, maximum_calls, at),
             {:ok, run} <-
               Captures.plan_run(
                 scope,
                 monitor.id,
                 run_plan(:manual, Ecto.UUID.generate(), maximum_calls)
               ),
             {:ok, run} <- Captures.enqueue_run(scope, run.id) do
          record_event!(monitor, user.id, "monitor.run_now_requested", at, %{
            "capture_run_id" => run.id,
            "maximum_call_count" => maximum_calls
          })

          run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def run_now(%Scope{}, _monitor_id, _options), do: {:error, :owner_required}

  def pause(scope, monitor_id, options \\ [])

  def pause(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        monitor_id,
        options
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      at = operation_time(options)

      result =
        with_locked_monitor(workspace_id, monitor_id, fn monitor ->
          case monitor.state do
            :paused ->
              monitor

            :active ->
              case monitor
                   |> Monitor.schedule_changeset(user, %{
                     state: :paused,
                     state_changed_at: state_time(at),
                     next_run_at: nil,
                     pause_reason: :owner_paused,
                     schedule_updated_at: at
                   })
                   |> Repo.update() do
                {:ok, paused} ->
                  record_event!(paused, user.id, "monitor.paused", at, %{
                    "reason" => "owner_paused"
                  })

                  paused

                {:error, changeset} ->
                  Repo.rollback(changeset)
              end

            _state ->
              Repo.rollback(:monitor_not_active)
          end
        end)

      case result do
        {:ok, monitor} ->
          _ = Captures.cancel_monitor_runs(scope, monitor.id)
          {:ok, monitor}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def pause(%Scope{}, _monitor_id, _options), do: {:error, :owner_required}

  def resume(scope, monitor_id, options \\ [])

  def resume(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        monitor_id,
        options
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      at = operation_time(options)

      with_locked_monitor(workspace_id, monitor_id, fn monitor ->
        with :ok <- ensure_paused(monitor),
             {:ok, maximum_calls} <- run_maximum_call_count(monitor),
             :ok <- ensure_eligible(scope, monitor, maximum_calls, at),
             {:ok, resumed} <-
               monitor
               |> Monitor.schedule_changeset(user, %{
                 state: :active,
                 state_changed_at: state_time(at),
                 next_run_at: Schedule.first_run_at(monitor.cadence, at),
                 pause_reason: nil,
                 schedule_updated_at: at
               })
               |> Repo.update() do
          record_event!(resumed, user.id, "monitor.resumed", at, %{
            "cadence" => Atom.to_string(resumed.cadence),
            "next_run_at" => iso8601(resumed.next_run_at)
          })

          record_schedule_activation!(scope, resumed, "resumed")

          resumed
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def resume(%Scope{}, _monitor_id, _options), do: {:error, :owner_required}

  defp record_schedule_activation!(scope, %Monitor{cadence: cadence} = monitor, activation_kind)
       when cadence in [:daily, :weekly] do
    ProductAnalytics.record!(scope, "schedule.activated", monitor.id, %{
      "activation_kind" => activation_kind,
      "cadence" => Atom.to_string(cadence)
    })
  end

  defp record_schedule_activation!(_scope, %Monitor{}, _activation_kind), do: :ok

  @doc false
  def sweep_ineligible(at \\ DateTime.utc_now(), limit \\ nil) do
    limit = limit || operations_config(:dispatcher_batch_size)

    ids =
      Monitor
      |> where([monitor], monitor.state == :active)
      |> order_by([monitor], asc: monitor.updated_at, asc: monitor.id)
      |> limit(^limit)
      |> select([monitor], monitor.id)
      |> Repo.all()

    results = Enum.map(ids, &inspect_active_monitor(&1, at))
    {:ok, summarize_results(results)}
  end

  @doc false
  def dispatch_due(at \\ DateTime.utc_now(), limit \\ nil) do
    limit = limit || operations_config(:dispatcher_batch_size)

    ids =
      Monitor
      |> where(
        [monitor],
        monitor.state == :active and monitor.cadence in [:daily, :weekly] and
          monitor.next_run_at <= ^at
      )
      |> order_by([monitor], asc: monitor.next_run_at, asc: monitor.id)
      |> limit(^limit)
      |> select([monitor], monitor.id)
      |> Repo.all()

    results = Enum.map(ids, &dispatch_monitor(&1, at))
    {:ok, summarize_results(results)}
  end

  defp inspect_active_monitor(monitor_id, at) do
    with %Monitor{workspace_id: workspace_id} <- Repo.get(Monitor, monitor_id) do
      result =
        with_locked_monitor(workspace_id, monitor_id, fn monitor ->
          if monitor.state != :active do
            :unchanged
          else
            case schedule_scope(monitor) do
              {:ok, scope} ->
                with {:ok, maximum_calls} <- run_maximum_call_count(monitor),
                     :ok <- ensure_eligible(scope, monitor, maximum_calls, at) do
                  :eligible
                else
                  {:error, reason} -> auto_pause_locked!(monitor, pause_reason(reason), at)
                end

              {:error, _reason} ->
                auto_pause_locked!(monitor, :schedule_owner_unavailable, at)
            end
          end
        end)

      maybe_cancel_auto_paused(monitor_id, result)
    else
      nil -> {:ok, :unchanged}
    end
  end

  defp dispatch_monitor(monitor_id, at) do
    with %Monitor{workspace_id: workspace_id} <- Repo.get(Monitor, monitor_id) do
      result =
        with_locked_monitor(workspace_id, monitor_id, fn monitor ->
          with :ok <- ensure_due(monitor, at),
               {:ok, scope} <- schedule_scope(monitor),
               {:ok, maximum_calls} <- run_maximum_call_count(monitor),
               :ok <- ensure_eligible(scope, monitor, maximum_calls, at) do
            intended_at = monitor.next_run_at
            identity = Schedule.identity(monitor.id, intended_at)

            if active_capture_run?(monitor.id) do
              skip_overlap(monitor, scope.user, intended_at, at)
            else
              case Captures.plan_run(
                     scope,
                     monitor.id,
                     run_plan(:scheduled, identity, maximum_calls)
                   ) do
                {:ok, run} ->
                  with {:ok, run} <- Captures.enqueue_run(scope, run.id),
                       {:ok, advanced} <- advance_schedule(monitor, intended_at, at) do
                    record_event!(advanced, scope.user.id, "monitor.scheduled", at, %{
                      "capture_run_id" => run.id,
                      "intended_at" => DateTime.to_iso8601(intended_at),
                      "next_run_at" => iso8601(advanced.next_run_at)
                    })

                    {:scheduled, run.id}
                  else
                    {:error, reason} -> Repo.rollback(reason)
                  end

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end
          else
            {:error, :not_due} ->
              :not_due

            {:error, :owner_unavailable} ->
              auto_pause_locked!(monitor, :schedule_owner_unavailable, at)

            {:error, reason} ->
              auto_pause_locked!(monitor, pause_reason(reason), at)
          end
        end)

      maybe_cancel_auto_paused(monitor_id, result)
    else
      nil -> {:ok, :not_due}
    end
  end

  defp with_locked_monitor(workspace_id, monitor_id, callback) do
    Repo.transaction(fn ->
      with %Workspace{} <- locked_workspace(workspace_id),
           %Monitor{} = monitor <- locked_monitor(workspace_id, monitor_id) do
        callback.(monitor)
      else
        nil -> Repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  defp ensure_eligible(scope, monitor, maximum_calls, at) do
    with :ok <- ensure_workspace_available(scope.workspace),
         {:ok, _snapshot} <- Baselines.current_compatible(scope, monitor.id),
         %MonitorVersion{} = version <- Repo.get(MonitorVersion, monitor.active_version_id),
         :ok <- ensure_credential(monitor, version),
         false <- repeated_authentication_failures?(monitor.id),
         :ok <- ensure_workspace_capacity(monitor.workspace_id, maximum_calls, at) do
      :ok
    else
      nil -> {:error, :incompatible_baseline}
      true -> {:error, :repeated_authentication_failures}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_workspace_available(%Workspace{status: :active, alpha_access: true}), do: :ok
  defp ensure_workspace_available(%Workspace{}), do: {:error, :workspace_unavailable}

  defp ensure_credential(monitor, version) do
    case Repo.get(ProviderCredential, monitor.provider_credential_id) do
      %ProviderCredential{
        workspace_id: workspace_id,
        provider: provider,
        status: :valid,
        last_validation_status: :succeeded,
        last_requested_model: requested_model,
        last_returned_model: requested_model
      }
      when workspace_id == monitor.workspace_id and provider == version.provider and
             requested_model == version.requested_model ->
        :ok

      _credential ->
        {:error, :credential_unavailable}
    end
  end

  defp ensure_workspace_capacity(workspace_id, maximum_calls, at) do
    committed = workspace_committed_calls_today(workspace_id, at)

    if committed + maximum_calls <= operations_config(:daily_workspace_call_limit),
      do: :ok,
      else: {:error, :workspace_call_limit}
  end

  defp workspace_committed_calls_today(workspace_id, at) do
    day_start = DateTime.new!(DateTime.to_date(at), ~T[00:00:00], "Etc/UTC")

    CaptureRun
    |> where(
      [run],
      run.workspace_id == ^workspace_id and
        (run.inserted_at >= ^day_start or run.status in ^@active_run_statuses or
           run.completed_at >= ^day_start)
    )
    |> select([run], coalesce(sum(run.maximum_call_count), 0))
    |> Repo.one()
  end

  defp repeated_authentication_failures?(monitor_id) do
    limit = operations_config(:repeated_authentication_failure_limit)

    runs =
      CaptureRun
      |> where(
        [run],
        run.monitor_id == ^monitor_id and run.kind in [:manual, :scheduled] and
          run.status in ^@terminal_run_statuses
      )
      |> order_by([run], desc: run.completed_at, desc: run.inserted_at, desc: run.id)
      |> limit(^limit)
      |> select([run], run.id)
      |> Repo.all()

    length(runs) == limit and
      Enum.all?(runs, fn run_id ->
        CaptureObservation
        |> where(
          [observation],
          observation.capture_run_id == ^run_id and
            observation.failure_category in [:authentication, :authorization]
        )
        |> Repo.exists?()
      end)
  end

  defp schedule_scope(%Monitor{schedule_updated_by_user_id: nil}),
    do: {:error, :owner_unavailable}

  defp schedule_scope(monitor) do
    with %User{} = user <- Repo.get(User, monitor.schedule_updated_by_user_id),
         %Workspace{} = workspace <- Repo.get(Workspace, monitor.workspace_id),
         %Membership{role: :owner} = membership <-
           Repo.get_by(Membership, workspace_id: workspace.id, user_id: user.id) do
      {:ok, Scope.for_workspace(user, workspace, membership)}
    else
      _reason -> {:error, :owner_unavailable}
    end
  end

  defp advance_schedule(monitor, intended_at, at) do
    monitor
    |> Monitor.system_schedule_changeset(%{
      last_scheduled_at: intended_at,
      next_run_at: Schedule.advance(monitor.cadence, intended_at, at)
    })
    |> Repo.update()
  end

  defp skip_overlap(monitor, user, intended_at, at) do
    with {:ok, advanced} <- advance_schedule(monitor, intended_at, at) do
      record_event!(advanced, user.id, "monitor.schedule_skipped_overlap", at, %{
        "intended_at" => DateTime.to_iso8601(intended_at),
        "next_run_at" => iso8601(advanced.next_run_at)
      })

      :skipped_overlap
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp active_capture_run?(monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.monitor_id == ^monitor_id and run.status in ^@active_run_statuses
    )
    |> Repo.exists?()
  end

  defp auto_pause_locked!(monitor, reason, at) do
    case monitor
         |> Monitor.system_schedule_changeset(%{
           state: :paused,
           state_changed_at: state_time(at),
           next_run_at: nil,
           pause_reason: reason
         })
         |> Repo.update() do
      {:ok, paused} ->
        record_event!(paused, nil, "monitor.auto_paused", at, %{
          "reason" => Atom.to_string(reason)
        })

        {:auto_paused, reason}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp maybe_cancel_auto_paused(monitor_id, {:ok, {:auto_paused, _reason}} = result) do
    _runs = Captures.cancel_monitor_runs(monitor_id)
    result
  end

  defp maybe_cancel_auto_paused(_monitor_id, result), do: result

  defp run_plan(kind, identity, maximum_calls) do
    identity_key =
      if String.starts_with?(identity, "#{kind}:"), do: identity, else: "#{kind}:#{identity}"

    %{
      identity_key: identity_key,
      kind: kind,
      samples_per_case: 1,
      retry_limit: 1,
      maximum_call_count: maximum_calls
    }
  end

  defp run_maximum_call_count(monitor) do
    case maximum_call_count(monitor) do
      count when count > 0 -> {:ok, count}
      _count -> {:error, :capture_not_ready}
    end
  end

  defp maximum_call_count(%Monitor{active_version_id: nil}), do: 0

  defp maximum_call_count(monitor) do
    active_cases =
      CaseVersion
      |> where(
        [case_version],
        case_version.monitor_version_id == ^monitor.active_version_id and
          case_version.status == :active
      )
      |> Repo.aggregate(:count)

    active_cases * 2
  end

  defp ensure_configurable_state(%Monitor{state: state})
       when state in [:baseline_pending, :active],
       do: :ok

  defp ensure_configurable_state(%Monitor{}), do: {:error, :monitor_not_configurable}
  defp ensure_active(%Monitor{state: :active}), do: :ok
  defp ensure_active(%Monitor{}), do: {:error, :monitor_not_active}
  defp ensure_paused(%Monitor{state: :paused}), do: :ok
  defp ensure_paused(%Monitor{}), do: {:error, :monitor_not_paused}

  defp ensure_due(%Monitor{state: :active, cadence: cadence, next_run_at: %DateTime{} = next}, at)
       when cadence in [:daily, :weekly] do
    if DateTime.compare(next, at) in [:lt, :eq], do: :ok, else: {:error, :not_due}
  end

  defp ensure_due(%Monitor{}, _at), do: {:error, :not_due}

  defp pause_reason(reason)
       when reason in [
              :credential_unavailable,
              :repeated_authentication_failures,
              :workspace_call_limit
            ],
       do: reason

  defp pause_reason(:owner_unavailable), do: :schedule_owner_unavailable
  defp pause_reason(_reason), do: :incompatible_configuration

  defp locked_workspace(workspace_id) do
    Workspace
    |> where([workspace], workspace.id == ^workspace_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_monitor(workspace_id, monitor_id) do
    Monitor
    |> where(
      [monitor],
      monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_monitor(workspace_id, monitor_id) do
    Repo.get_by(Monitor, workspace_id: workspace_id, id: monitor_id)
  end

  defp last_run(workspace_id, monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.workspace_id == ^workspace_id and run.monitor_id == ^monitor_id and
        run.kind in [:manual, :scheduled]
    )
    |> order_by([run], desc: run.inserted_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  defp unresolved_alert_count(scope, monitor_id) do
    case RunResults.unresolved_alert_count(scope, monitor_id) do
      {:ok, count} -> count
      {:error, _reason} -> 0
    end
  end

  defp record_event!(monitor, actor_user_id, action, at, metadata) do
    Audit.record_event!(%{
      action: action,
      target_type: "monitor",
      target_id: monitor.id,
      workspace_id: monitor.workspace_id,
      actor_user_id: actor_user_id,
      occurred_at: state_time(at),
      metadata: metadata
    })
  end

  defp summarize_results(results) do
    Enum.reduce(results, %{eligible: 0, scheduled: 0, skipped: 0, paused: 0, unchanged: 0}, fn
      {:ok, :eligible}, counts -> Map.update!(counts, :eligible, &(&1 + 1))
      {:ok, {:scheduled, _run_id}}, counts -> Map.update!(counts, :scheduled, &(&1 + 1))
      {:ok, :skipped_overlap}, counts -> Map.update!(counts, :skipped, &(&1 + 1))
      {:ok, {:auto_paused, _reason}}, counts -> Map.update!(counts, :paused, &(&1 + 1))
      _result, counts -> Map.update!(counts, :unchanged, &(&1 + 1))
    end)
  end

  defp operation_time(options) do
    options
    |> Keyword.get(:at, DateTime.utc_now())
    |> DateTime.truncate(:second)
  end

  defp state_time(at), do: DateTime.truncate(at, :second)
  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)

  defp operations_config(key) do
    :silent_regression
    |> Application.fetch_env!(:monitor_operations)
    |> Keyword.fetch!(key)
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
