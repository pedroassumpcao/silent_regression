defmodule SilentRegression.MonitorOperations do
  @moduledoc """
  Owner-controlled monitor scheduling and workspace-scoped operational state.

  Tenant schedules are durable monitor state. Every spend-producing path is serialized through
  workspace and monitor locks, then delegated to the capture pipeline.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}

  alias SilentRegression.{
    Audit,
    Baselines,
    Captures,
    Notifications,
    PilotPolicies,
    ProductAnalytics
  }

  alias SilentRegression.Captures.{CaptureObservation, CaptureRun}
  alias SilentRegression.MonitorOperations.AuthenticationRecovery
  alias SilentRegression.MonitorOperations.Schedule
  alias SilentRegression.Monitors.{CaseVersion, Monitor, MonitorVersion}
  alias SilentRegression.ProviderCredentials
  alias SilentRegression.ProviderCredentials.{ModelValidation, ProviderCredential}
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
      now = DateTime.utc_now()
      usage = PilotPolicies.usage(scope)

      {:ok,
       %{
         monitor: monitor,
         last_run: last_run,
         unresolved_alerts: unresolved_alert_count(scope, monitor.id),
         approved_baseline?: Baselines.compatible_approved?(scope, monitor.id),
         authentication_recovery: authentication_recovery_state(monitor),
         coverage: coverage_state(monitor, last_successful_run(workspace_id, monitor.id), now),
         maximum_call_count: maximum_call_count(monitor),
         pilot_usage: usage,
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
                 capacity_wait_reason: nil,
                 capacity_retry_at: nil,
                 capacity_intended_at: nil,
                 coverage_interrupted_at: nil,
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
                 run_plan(:manual, Ecto.UUID.generate(), maximum_calls, at)
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
                     capacity_wait_reason: nil,
                     capacity_retry_at: nil,
                     capacity_intended_at: nil,
                     coverage_interrupted_at: nil,
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
                 capacity_wait_reason: nil,
                 capacity_retry_at: nil,
                 capacity_intended_at: nil,
                 coverage_interrupted_at: nil,
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

  def authorize_authentication_recovery(scope, monitor_id, options \\ [])

  def authorize_authentication_recovery(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner}
        } = scope,
        monitor_id,
        options
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Monitor{} = monitor <- load_monitor(workspace_id, monitor_id),
         %MonitorVersion{} = version <- Repo.get(MonitorVersion, monitor.active_version_id),
         %ProviderCredential{} = credential <- recovery_credential(monitor, version),
         breaker <- authentication_breaker(monitor.id),
         :ok <- ensure_recovery_precheck(scope, monitor, breaker),
         {:ok, _validated} <-
           ProviderCredentials.validate_credential(scope, credential.id, %{
             model: version.requested_model
           }) do
      finalize_authentication_recovery(
        scope,
        monitor.id,
        recovery_time(options)
      )
    else
      :error -> {:error, :not_found}
      nil -> {:error, :capture_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_authentication_recovery(%Scope{}, _monitor_id, _options),
    do: {:error, :owner_required}

  defp record_schedule_activation!(scope, %Monitor{cadence: cadence} = monitor, activation_kind) do
    properties = %{
      "activation_kind" => activation_kind,
      "cadence" => Atom.to_string(cadence)
    }

    ProductAnalytics.record!(scope, "monitor.activated", monitor.id, properties)

    if cadence in [:daily, :weekly] do
      ProductAnalytics.record!(scope, "schedule.activated", monitor.id, properties)
    end
  end

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
                     :ok <- ensure_persistently_eligible(scope, monitor, maximum_calls) do
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
               :ok <- ensure_persistently_eligible(scope, monitor, maximum_calls),
               :ok <- PilotPolicies.check_capacity(monitor.workspace_id, maximum_calls, at) do
            intended_at = monitor.capacity_intended_at || monitor.next_run_at
            identity = Schedule.identity(monitor.id, intended_at)

            if active_capture_run?(monitor.id) do
              skip_overlap(monitor, scope.user, intended_at, at)
            else
              case Captures.plan_run(
                     scope,
                     monitor.id,
                     run_plan(:scheduled, identity, maximum_calls, at)
                   ) do
                {:ok, run} ->
                  with {:ok, run} <- Captures.enqueue_run(scope, run.id),
                       {:ok, advanced} <- advance_schedule(monitor, intended_at, at) do
                    record_event!(advanced, scope.user.id, "monitor.scheduled", at, %{
                      "capture_run_id" => run.id,
                      "intended_at" => DateTime.to_iso8601(intended_at),
                      "next_run_at" => iso8601(advanced.next_run_at)
                    })

                    record_capacity_recovery!(monitor, advanced, run.id, scope.user.id, at)

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

            {:error, reason}
            when reason in [:workspace_run_limit, :workspace_call_limit] ->
              wait_for_capacity_locked!(monitor, reason, at)

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
    with :ok <- ensure_persistently_eligible(scope, monitor, maximum_calls),
         :ok <- PilotPolicies.check_capacity(monitor.workspace_id, maximum_calls, at) do
      :ok
    end
  end

  defp ensure_persistently_eligible(scope, monitor, maximum_calls) do
    with :ok <- ensure_workspace_available(scope.workspace),
         {:ok, _snapshot} <- Baselines.current_compatible(scope, monitor.id),
         %MonitorVersion{} = version <- Repo.get(MonitorVersion, monitor.active_version_id),
         :ok <- ensure_credential(monitor, version),
         false <- authentication_breaker(monitor.id).tripped?,
         :ok <- PilotPolicies.check_run_limit(monitor.workspace_id, maximum_calls) do
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
        status: :valid
      } = credential
      when workspace_id == monitor.workspace_id and provider == version.provider ->
        if ProviderCredentials.model_access_verified?(credential, version.requested_model),
          do: :ok,
          else: {:error, :credential_unavailable}

      _credential ->
        {:error, :credential_unavailable}
    end
  end

  defp ensure_recovery_precheck(scope, %Monitor{state: :paused} = monitor, %{tripped?: true}) do
    with {:ok, _baseline} <- Baselines.current_compatible(scope, monitor.id),
         false <- active_capture_run?(monitor.id) do
      :ok
    else
      true -> {:error, :run_in_progress}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_recovery_precheck(_scope, %Monitor{}, _breaker),
    do: {:error, :authentication_recovery_unavailable}

  defp finalize_authentication_recovery(scope, monitor_id, at) do
    with_locked_monitor(scope.workspace.id, monitor_id, fn monitor ->
      breaker = authentication_breaker(monitor.id)

      with :ok <- ensure_recovery_precheck(scope, monitor, breaker),
           %MonitorVersion{} = version <- Repo.get(MonitorVersion, monitor.active_version_id),
           %ProviderCredential{status: :valid} = credential <-
             recovery_credential(monitor, version),
           %ModelValidation{} = validation <-
             ProviderCredentials.exact_model_validation(credential, version.requested_model),
           true <- fresh_validation?(validation, breaker),
           epoch <- next_recovery_epoch(monitor.id),
           {:ok, run} <- plan_authentication_probe(scope, monitor, epoch),
           {:ok, recovery} <-
             %AuthenticationRecovery{}
             |> AuthenticationRecovery.create_changeset(
               monitor,
               credential,
               validation,
               run,
               scope.user,
               epoch,
               at
             )
             |> Repo.insert(),
           {:ok, run} <- Captures.enqueue_run(scope, run.id) do
        record_event!(
          monitor,
          scope.user.id,
          "monitor.authentication_recovery_authorized",
          at,
          %{
            "recovery_id" => recovery.id,
            "epoch" => epoch,
            "capture_run_id" => run.id,
            "provider_credential_id" => credential.id,
            "requested_model" => version.requested_model,
            "maximum_call_count" => 1,
            "retry_limit" => 0
          }
        )

        %{recovery: recovery, run: run}
      else
        nil -> Repo.rollback(:capture_not_ready)
        false -> Repo.rollback(:fresh_model_validation_required)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp plan_authentication_probe(scope, monitor, epoch) do
    Captures.plan_run(scope, monitor.id, %{
      identity_key: "authentication_probe:#{monitor.id}:#{epoch}",
      kind: :authentication_probe,
      samples_per_case: 1,
      retry_limit: 0,
      maximum_call_count: 1
    })
  end

  defp recovery_credential(monitor, version) do
    case Repo.get(ProviderCredential, monitor.provider_credential_id) do
      %ProviderCredential{workspace_id: workspace_id, provider: provider} = credential
      when workspace_id == monitor.workspace_id and provider == version.provider ->
        credential

      _credential ->
        nil
    end
  end

  defp fresh_validation?(validation, %{tripped_at: %DateTime{} = tripped_at}) do
    DateTime.after?(validation.validated_at, tripped_at)
  end

  defp fresh_validation?(_validation, _breaker), do: false

  defp next_recovery_epoch(monitor_id) do
    AuthenticationRecovery
    |> where([recovery], recovery.monitor_id == ^monitor_id)
    |> Repo.aggregate(:max, :epoch)
    |> case do
      nil -> 1
      epoch -> epoch + 1
    end
  end

  defp authentication_breaker(monitor_id) do
    limit = operations_config(:repeated_authentication_failure_limit)
    cutoff = latest_successful_recovery_at(monitor_id)

    query =
      CaptureRun
      |> where(
        [run],
        run.monitor_id == ^monitor_id and run.kind in [:manual, :scheduled] and
          run.status in ^@terminal_run_statuses
      )

    query =
      if cutoff do
        where(query, [run], run.completed_at > ^cutoff)
      else
        query
      end

    runs =
      query
      |> order_by([run], desc: run.completed_at, desc: run.inserted_at, desc: run.id)
      |> limit(^limit)
      |> select([run], %{id: run.id, completed_at: run.completed_at})
      |> Repo.all()

    tripped? =
      length(runs) == limit and Enum.all?(runs, &authentication_failure_run?(&1.id))

    %{
      tripped?: tripped?,
      tripped_at: if(tripped?, do: hd(runs).completed_at, else: nil),
      successful_recovery_at: cutoff
    }
  end

  defp authentication_failure_run?(run_id) do
    CaptureObservation
    |> where(
      [observation],
      observation.capture_run_id == ^run_id and
        observation.failure_category in [:authentication, :authorization]
    )
    |> Repo.exists?()
  end

  defp latest_successful_recovery_at(monitor_id) do
    AuthenticationRecovery
    |> join(:inner, [recovery], run in CaptureRun, on: run.id == recovery.capture_run_id)
    |> where(
      [recovery, run],
      recovery.monitor_id == ^monitor_id and run.status == :succeeded
    )
    |> order_by([_recovery, run], desc: run.completed_at, desc: run.id)
    |> limit(1)
    |> select([_recovery, run], run.completed_at)
    |> Repo.one()
  end

  defp authentication_recovery_state(monitor) do
    breaker = authentication_breaker(monitor.id)
    latest = latest_authentication_recovery(monitor.id)
    status = authentication_recovery_status(monitor, breaker, latest)

    %{
      required?: breaker.tripped?,
      status: status,
      tripped_at: breaker.tripped_at,
      epoch: latest && latest.epoch,
      authorized_at: latest && latest.authorized_at,
      credential_validated_at: latest && latest.credential_validated_at,
      capture_run_id: latest && latest.capture_run_id,
      probe_status: latest && latest.capture_run.status,
      failure_category: recovery_failure_category(latest),
      validation_call_count: if(status, do: 1, else: 0),
      maximum_call_count: if(status, do: 1, else: 0),
      retry_limit: 0
    }
  end

  defp latest_authentication_recovery(monitor_id) do
    AuthenticationRecovery
    |> where([recovery], recovery.monitor_id == ^monitor_id)
    |> order_by([recovery], desc: recovery.epoch)
    |> limit(1)
    |> preload(capture_run: :observations)
    |> Repo.one()
  end

  defp authentication_recovery_status(_monitor, %{tripped?: true, tripped_at: tripped_at}, latest) do
    cond do
      is_nil(latest) -> :ready
      not DateTime.after?(latest.credential_validated_at, tripped_at) -> :ready
      latest.capture_run.status in @active_run_statuses -> :in_progress
      latest.capture_run.status == :succeeded -> :succeeded
      true -> :failed
    end
  end

  defp authentication_recovery_status(
         %Monitor{state: :paused, pause_reason: :repeated_authentication_failures},
         _breaker,
         %AuthenticationRecovery{capture_run: %CaptureRun{status: :succeeded}}
       ),
       do: :succeeded

  defp authentication_recovery_status(_monitor, _breaker, _latest), do: nil

  defp recovery_failure_category(nil), do: nil

  defp recovery_failure_category(%AuthenticationRecovery{capture_run: run}) do
    run.observations
    |> Enum.find_value(& &1.failure_category)
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
      next_run_at: Schedule.advance(monitor.cadence, intended_at, at),
      capacity_wait_reason: nil,
      capacity_retry_at: nil,
      capacity_intended_at: nil,
      coverage_interrupted_at: nil
    })
    |> Repo.update()
  end

  defp wait_for_capacity_locked!(monitor, reason, at) do
    intended_at = monitor.capacity_intended_at || monitor.next_run_at
    retry_at = PilotPolicies.next_reset_at(at)

    event =
      if monitor.capacity_wait_reason,
        do: "monitor.capacity_wait_extended",
        else: "monitor.capacity_wait_started"

    case monitor
         |> Monitor.capacity_wait_changeset(reason, intended_at, retry_at, at)
         |> Repo.update() do
      {:ok, waiting} ->
        record_event!(waiting, monitor.schedule_updated_by_user_id, event, at, %{
          "reason" => Atom.to_string(reason),
          "intended_at" => iso8601(intended_at),
          "retry_at" => iso8601(retry_at)
        })

        Notifications.prepare_capacity_wait!(waiting, reason, intended_at, retry_at)
        {:waiting_capacity, reason}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp record_capacity_recovery!(
         %Monitor{capacity_wait_reason: nil},
         _advanced,
         _capture_run_id,
         _actor_user_id,
         _at
       ),
       do: :ok

  defp record_capacity_recovery!(monitor, advanced, capture_run_id, actor_user_id, at) do
    record_event!(advanced, actor_user_id, "monitor.capacity_wait_recovered", at, %{
      "reason" => Atom.to_string(monitor.capacity_wait_reason),
      "intended_at" => iso8601(monitor.capacity_intended_at),
      "capture_run_id" => capture_run_id
    })
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
           pause_reason: reason,
           capacity_wait_reason: nil,
           capacity_retry_at: nil,
           capacity_intended_at: nil,
           coverage_interrupted_at: nil
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

  defp run_plan(kind, identity, maximum_calls, capacity_at) do
    identity_key =
      if String.starts_with?(identity, "#{kind}:"), do: identity, else: "#{kind}:#{identity}"

    %{
      identity_key: identity_key,
      kind: kind,
      samples_per_case: 1,
      retry_limit: 1,
      maximum_call_count: maximum_calls,
      capacity_at: capacity_at
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
              :per_run_call_limit
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

  defp last_successful_run(workspace_id, monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.workspace_id == ^workspace_id and run.monitor_id == ^monitor_id and
        run.kind in [:manual, :scheduled] and run.status == :succeeded
    )
    |> order_by([run], desc: run.completed_at, desc: run.inserted_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  defp coverage_state(monitor, last_successful_run, now) do
    waiting? = not is_nil(monitor.capacity_wait_reason)

    overdue_since =
      cond do
        waiting? ->
          monitor.capacity_intended_at

        monitor.state == :active and monitor.cadence in [:daily, :weekly] and
          match?(%DateTime{}, monitor.next_run_at) and DateTime.before?(monitor.next_run_at, now) ->
          monitor.next_run_at

        true ->
          nil
      end

    %{
      status: coverage_status(monitor, waiting?),
      capacity_reason: monitor.capacity_wait_reason,
      retry_at: monitor.capacity_retry_at,
      intended_at: monitor.capacity_intended_at,
      interrupted_at: monitor.coverage_interrupted_at,
      last_successful_at: last_successful_run && last_successful_run.completed_at,
      overdue?: not is_nil(overdue_since),
      overdue_since: overdue_since
    }
  end

  defp coverage_status(_monitor, true), do: :waiting_capacity
  defp coverage_status(%Monitor{state: :paused}, false), do: :paused
  defp coverage_status(%Monitor{cadence: :manual}, false), do: :manual
  defp coverage_status(%Monitor{}, false), do: :on_schedule

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
    Enum.reduce(
      results,
      %{eligible: 0, scheduled: 0, skipped: 0, waiting: 0, paused: 0, unchanged: 0},
      fn
        {:ok, :eligible}, counts -> Map.update!(counts, :eligible, &(&1 + 1))
        {:ok, {:scheduled, _run_id}}, counts -> Map.update!(counts, :scheduled, &(&1 + 1))
        {:ok, :skipped_overlap}, counts -> Map.update!(counts, :skipped, &(&1 + 1))
        {:ok, {:waiting_capacity, _reason}}, counts -> Map.update!(counts, :waiting, &(&1 + 1))
        {:ok, {:auto_paused, _reason}}, counts -> Map.update!(counts, :paused, &(&1 + 1))
        _result, counts -> Map.update!(counts, :unchanged, &(&1 + 1))
      end
    )
  end

  defp operation_time(options) do
    options
    |> Keyword.get(:at, DateTime.utc_now())
    |> DateTime.truncate(:second)
  end

  defp recovery_time(options) do
    Keyword.get(options, :at, DateTime.utc_now())
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
