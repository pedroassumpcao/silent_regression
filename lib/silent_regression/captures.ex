defmodule SilentRegression.Captures do
  @moduledoc """
  Durable workspace-scoped capture planning, provider accounting, and local evaluation.

  Provider calls are ledger-first: every network attempt is reserved before it is made, and an
  abandoned reservation becomes an explicit unknown outcome rather than a silent replay.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Baselines

  alias SilentRegression.Captures.{
    CaptureEvaluation,
    CaptureObservation,
    CaptureRuleResult,
    CaptureRun,
    EvaluationPersistence,
    ProviderAttempt
  }

  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Monitors.{CaseVersion, Monitor, MonitorVersion}
  alias SilentRegression.PilotPolicies
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Providers
  alias SilentRegression.Providers.{CompletionRequest, CompletionResult, Failure, RequestArtifact}
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @terminal_run_statuses [:succeeded, :partial_failed, :failed, :cancelled, :needs_review]
  @terminal_observation_statuses [:succeeded, :failed, :unknown, :cancelled]

  def plan_run(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        } = scope,
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with {:ok, resources} <- planning_resources(workspace_id, monitor_id),
             {:ok, plan} <- normalize_plan(attrs, length(resources.cases)),
             resources <- attach_baseline_snapshot(scope, monitor_id, resources, plan),
             {:ok, run} <- find_or_insert_run(resources, user, plan) do
          Repo.preload(run,
            observations:
              from(observation in CaptureObservation, order_by: observation.sample_index)
          )
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def plan_run(%Scope{}, _monitor_id, _attrs), do: {:error, :workspace_required}

  def enqueue_run(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        run_id
      ) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      Repo.transaction(fn ->
        case locked_run(workspace_id, run_id) do
          %CaptureRun{status: :planned, kind: :baseline} = run ->
            if Baselines.authorized_baseline_run?(run.id) do
              enqueue_observations!(run)
            else
              Repo.rollback(:authorization_required)
            end

          %CaptureRun{status: :planned} = run ->
            enqueue_observations!(run)

          %CaptureRun{} = run ->
            run

          nil ->
            Repo.rollback(:not_found)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def enqueue_run(%Scope{}, _run_id), do: {:error, :workspace_required}

  defp enqueue_observations!(run) do
    observations = load_observations(run.id)

    Enum.each(observations, fn observation ->
      case Oban.insert(
             ObservationWorker.new(%{
               capture_run_id: run.id,
               observation_id: observation.id
             })
           ) do
        {:ok, _job} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    run
    |> CaptureRun.lifecycle_changeset(%{status: :queued})
    |> Repo.update!()
  end

  def get_run(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        run_id
      ) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id),
         %CaptureRun{} = run <- load_run(workspace_id, run_id) do
      {:ok, preload_run(run)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_run(%Scope{}, _run_id), do: {:error, :workspace_required}

  def cancel_run(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        run_id
      ) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id),
         {:ok, run} <- cancel_run_transaction(workspace_id, run_id) do
      cancel_queued_jobs(run.id)
      {:ok, preload_run(Repo.get!(CaptureRun, run.id))}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_run(%Scope{}, _run_id), do: {:error, :workspace_required}

  def cancel_monitor_runs(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         true <- monitor_in_workspace?(workspace_id, monitor_id) do
      {:ok, cancel_active_monitor_runs(workspace_id, monitor_id)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def cancel_monitor_runs(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  @doc false
  def cancel_monitor_runs(monitor_id) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Monitor{workspace_id: workspace_id} <- Repo.get(Monitor, monitor_id) do
      cancel_active_monitor_runs(workspace_id, monitor_id)
    else
      _reason -> []
    end
  end

  @doc false
  def execute_observation(capture_run_id, observation_id) do
    with {:ok, capture_run_id} <- Ecto.UUID.cast(capture_run_id),
         {:ok, observation_id} <- Ecto.UUID.cast(observation_id) do
      case reserve_attempt(capture_run_id, observation_id) do
        {:ok, {:call, run, observation, attempt, credential, request}} ->
          perform_provider_attempt(run, observation, attempt, credential, request)

        {:ok, {:ensure_evaluation, run, observation}} ->
          ensure_evaluation_and_finalize(run, observation)

        {:ok, {:busy, seconds}} ->
          {:retry, seconds}

        {:ok, :done} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp planning_resources(workspace_id, monitor_id) do
    with %Monitor{} = monitor <- locked_monitor(workspace_id, monitor_id),
         %MonitorVersion{} = monitor_version <- active_monitor_version(monitor),
         %ContractVersion{} = contract_version <-
           approved_contract(monitor.id, monitor_version.id),
         %ProviderCredential{} = credential <- valid_credential(monitor, monitor_version.provider),
         cases when cases != [] <- Enum.filter(monitor_version.cases, &(&1.status == :active)) do
      {:ok,
       %{
         workspace_id: workspace_id,
         monitor: monitor,
         monitor_version: monitor_version,
         contract_version: contract_version,
         credential: credential,
         cases: cases
       }}
    else
      nil -> {:error, :capture_not_ready}
      [] -> {:error, :capture_not_ready}
    end
  end

  defp normalize_plan(attrs, case_count) when case_count > 0 do
    with {:ok, identity_key} <- identity_key(value(attrs, :identity_key)),
         {:ok, kind} <- run_kind(value(attrs, :kind)),
         {:ok, samples_per_case} <-
           bounded_integer(
             value(attrs, :samples_per_case, 1),
             1,
             capture_limit(:max_samples_per_case)
           ),
         {:ok, retry_limit} <-
           bounded_integer(value(attrs, :retry_limit, 1), 0, capture_limit(:max_retry_limit)) do
      planned_call_count = case_count * samples_per_case
      theoretical_maximum = planned_call_count * (retry_limit + 1)

      with {:ok, maximum_call_count} <-
             bounded_integer(
               value(attrs, :maximum_call_count, theoretical_maximum),
               planned_call_count,
               min(theoretical_maximum, capture_limit(:max_calls_per_run))
             ) do
        {:ok,
         %{
           identity_key: identity_key,
           kind: kind,
           samples_per_case: samples_per_case,
           retry_limit: retry_limit,
           planned_call_count: planned_call_count,
           maximum_call_count: maximum_call_count
         }}
      end
    end
  end

  defp normalize_plan(_attrs, _case_count), do: {:error, :capture_not_ready}

  defp find_or_insert_run(resources, user, plan) do
    case run_by_identity(resources.workspace_id, plan.identity_key, lock: true) do
      %CaptureRun{} = run ->
        if matching_plan?(run, resources, plan),
          do: {:ok, run},
          else: {:error, :identity_conflict}

      nil ->
        with :ok <-
               PilotPolicies.authorize_new_run(
                 resources.workspace_id,
                 plan.maximum_call_count
               ) do
          case active_run_for_monitor(resources.monitor.id) do
            nil -> insert_run(resources, user, plan)
            %CaptureRun{} -> {:error, :run_in_progress}
          end
        end
    end
  end

  defp insert_run(resources, user, plan) do
    attrs =
      Map.merge(plan, %{
        provider: resources.monitor_version.provider,
        requested_model: resources.monitor_version.requested_model,
        monitor_fingerprint: resources.monitor_version.fingerprint,
        case_set_fingerprint: resources.monitor_version.case_set_fingerprint,
        contract_fingerprint: resources.contract_version.fingerprint,
        contract_semantics_fingerprint: resources.contract_version.contract_fingerprint,
        evaluator_engine_version: resources.contract_version.evaluator_engine_version
      })

    associations = %{
      workspace_id: resources.workspace_id,
      monitor_id: resources.monitor.id,
      monitor_version_id: resources.monitor_version.id,
      contract_version_id: resources.contract_version.id,
      provider_credential_id: resources.credential.id,
      baseline_snapshot_id: resources.baseline_snapshot && resources.baseline_snapshot.id,
      created_by_user_id: user.id
    }

    with {:ok, run} <-
           %CaptureRun{} |> CaptureRun.create_changeset(associations, attrs) |> Repo.insert(),
         :ok <- insert_observations(run, resources) do
      {:ok, run}
    end
  end

  defp insert_observations(run, resources) do
    resources.cases
    |> Enum.sort_by(&{&1.position, &1.id})
    |> Enum.reduce_while(:ok, fn case_version, :ok ->
      case RequestArtifact.build(resources.monitor_version, case_version) do
        {:ok, built} ->
          Enum.reduce_while(0..(run.samples_per_case - 1), :ok, fn sample_index, :ok ->
            result =
              %CaptureObservation{}
              |> CaptureObservation.create_changeset(run, case_version, %{
                sample_index: sample_index,
                case_fingerprint: case_version.fingerprint,
                request_fingerprint: built.fingerprint
              })
              |> Repo.insert()

            case result do
              {:ok, _observation} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
          |> case do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp matching_plan?(run, resources, plan) do
    run.monitor_id == resources.monitor.id and
      run.monitor_version_id == resources.monitor_version.id and
      run.contract_version_id == resources.contract_version.id and
      run.provider_credential_id == resources.credential.id and
      run.baseline_snapshot_id == baseline_snapshot_id(resources) and
      run.provider == resources.monitor_version.provider and
      run.requested_model == resources.monitor_version.requested_model and
      run.monitor_fingerprint == resources.monitor_version.fingerprint and
      run.case_set_fingerprint == resources.monitor_version.case_set_fingerprint and
      run.contract_fingerprint == resources.contract_version.fingerprint and
      run.evaluator_engine_version == resources.contract_version.evaluator_engine_version and
      run.kind == plan.kind and run.samples_per_case == plan.samples_per_case and
      run.retry_limit == plan.retry_limit and
      run.planned_call_count == plan.planned_call_count and
      run.maximum_call_count == plan.maximum_call_count
  end

  defp attach_baseline_snapshot(_scope, _monitor_id, resources, %{kind: :baseline}) do
    Map.put(resources, :baseline_snapshot, nil)
  end

  defp attach_baseline_snapshot(scope, monitor_id, resources, %{kind: kind})
       when kind in [:manual, :scheduled] do
    baseline_snapshot =
      case Baselines.current_compatible(scope, monitor_id) do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> nil
      end

    Map.put(resources, :baseline_snapshot, baseline_snapshot)
  end

  defp baseline_snapshot_id(%{baseline_snapshot: nil}), do: nil
  defp baseline_snapshot_id(%{baseline_snapshot: snapshot}), do: snapshot.id

  defp reserve_attempt(run_id, observation_id) do
    Repo.transaction(fn ->
      with %CaptureRun{} = run <- locked_run_by_id(run_id),
           %CaptureObservation{} = observation <- locked_observation(run.id, observation_id) do
        reserve_locked(run, observation)
      else
        nil -> Repo.rollback(:not_found)
      end
    end)
  end

  defp reserve_locked(run, %CaptureObservation{status: :succeeded} = observation),
    do: {:ensure_evaluation, run, observation}

  defp reserve_locked(_run, %CaptureObservation{status: status})
       when status in @terminal_observation_statuses,
       do: :done

  defp reserve_locked(run, observation) do
    cond do
      run.status == :cancelled or not is_nil(run.cancellation_requested_at) ->
        cancel_observation!(observation)
        finalize_run!(run)
        :done

      run.kind in [:manual, :scheduled] and not execution_allowed?(run) ->
        cancel_ineligible_run!(run)
        :done

      started_attempt = started_attempt(observation.id) ->
        handle_started_attempt!(run, observation, started_attempt)

      true ->
        run = ensure_run_started!(run)
        prepare_reserved_attempt(run, observation)
    end
  end

  defp execution_allowed?(run) do
    monitor_state =
      Monitor
      |> where(
        [monitor],
        monitor.id == ^run.monitor_id and monitor.workspace_id == ^run.workspace_id and
          monitor.active_version_id == ^run.monitor_version_id and
          monitor.provider_credential_id == ^run.provider_credential_id
      )
      |> select([monitor], monitor.state)
      |> Repo.one()

    credential_valid? =
      ProviderCredential
      |> where(
        [credential],
        credential.id == ^run.provider_credential_id and
          credential.workspace_id == ^run.workspace_id and credential.provider == ^run.provider and
          credential.status == :valid
      )
      |> Repo.exists?()

    credential_valid? and
      case monitor_state do
        :baseline_pending -> true
        :active -> Baselines.capture_run_compatible?(run)
        _state -> false
      end
  end

  defp cancel_ineligible_run!(run) do
    now = DateTime.utc_now()

    CaptureObservation
    |> where(
      [observation],
      observation.capture_run_id == ^run.id and
        observation.status in [:planned, :retrying]
    )
    |> Repo.update_all(set: [status: :cancelled, terminal_at: now, updated_at: now])

    run
    |> CaptureRun.lifecycle_changeset(%{cancellation_requested_at: now})
    |> Repo.update!()
    |> finalize_run!()
  end

  defp handle_started_attempt!(run, observation, attempt) do
    now = DateTime.utc_now()

    if DateTime.after?(attempt.lease_expires_at, now) do
      {:busy, max(DateTime.diff(attempt.lease_expires_at, now, :second), 1)}
    else
      attempt
      |> ProviderAttempt.result_changeset(%{
        status: :unknown,
        retryable: false,
        failure_category: :unknown_outcome,
        failure_message:
          "The worker stopped after reserving a provider call; its outcome is unknown.",
        finished_at: now
      })
      |> Repo.update!()

      observation
      |> CaptureObservation.lifecycle_changeset(%{
        status: :unknown,
        requested_model: run.requested_model,
        completion_state: :unknown,
        failure_category: :unknown_outcome,
        failure_message: "A reserved provider call has an unknown outcome and was not replayed.",
        terminal_at: now
      })
      |> Repo.update!()

      finalize_run!(run)
      :done
    end
  end

  defp prepare_reserved_attempt(run, observation) do
    call_count = attempt_count(run.id)

    cond do
      call_count >= run.maximum_call_count ->
        fail_without_attempt!(
          run,
          observation,
          :call_cap_exceeded,
          "The run call cap was reached."
        )

      true ->
        with {:ok, credential, case_version, built} <-
               execution_resources(run, observation) do
          now = DateTime.utc_now()
          attempt_number = observation_attempt_count(observation.id) + 1
          client_request_id = Ecto.UUID.generate()

          attempt =
            %ProviderAttempt{}
            |> ProviderAttempt.create_changeset(run, observation, %{
              attempt_number: attempt_number,
              client_request_id: client_request_id,
              request_mode: built.mode,
              request_schema_version: built.schema_version,
              request_fingerprint: built.fingerprint,
              request_artifact: built.artifact,
              started_at: now,
              lease_expires_at: DateTime.add(now, capture_limit(:attempt_lease_seconds), :second)
            })
            |> Repo.insert!()

          observation =
            observation
            |> CaptureObservation.lifecycle_changeset(%{status: :running})
            |> Repo.update!()

          request = %CompletionRequest{
            case_id: case_version.case_key,
            attempt_number: attempt_number,
            requested_model: run.requested_model,
            request_mode: built.mode,
            request_schema_version: built.schema_version,
            request_artifact: built.artifact,
            request_fingerprint: built.fingerprint,
            client_request_id: client_request_id
          }

          {:call, run, observation, attempt, credential, request}
        else
          {:error, :credential_unavailable} ->
            fail_without_attempt!(
              run,
              observation,
              :credential_unavailable,
              "The configured provider credential is unavailable."
            )

          {:error, _reason} ->
            fail_without_attempt!(
              run,
              observation,
              :invalid_request,
              "The provider request artifact could not be reproduced safely."
            )
        end
    end
  end

  defp execution_resources(run, observation) do
    credential =
      ProviderCredential
      |> where(
        [credential],
        credential.id == ^run.provider_credential_id and
          credential.workspace_id == ^run.workspace_id and
          credential.provider == ^run.provider and credential.status == :valid
      )
      |> Repo.one()

    case_version =
      CaseVersion
      |> where(
        [case_version],
        case_version.id == ^observation.case_version_id and
          case_version.monitor_version_id == ^run.monitor_version_id
      )
      |> Repo.one()

    monitor_version = Repo.get(MonitorVersion, run.monitor_version_id)

    with %ProviderCredential{} = credential <- credential,
         %CaseVersion{} = case_version <- case_version,
         %MonitorVersion{} = monitor_version <- monitor_version,
         {:ok, built} <- RequestArtifact.build(monitor_version, case_version),
         true <- built.fingerprint == observation.request_fingerprint do
      {:ok, credential, case_version, built}
    else
      nil -> {:error, :credential_unavailable}
      false -> {:error, :request_fingerprint_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_provider_attempt(run, observation, attempt, credential, request) do
    case Providers.complete_once(run.provider, credential.secret, request) do
      {:ok, %CompletionResult{} = result} ->
        with {:ok, observation} <- persist_success(run, observation, attempt, result),
             :ok <- ensure_evaluation_and_finalize(run, observation) do
          :ok
        else
          {:error, :attempt_no_longer_active} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, %Failure{} = failure} ->
        persist_failure(run, observation, attempt, failure)
    end
  end

  defp persist_success(run, observation, attempt, result) do
    Repo.transaction(fn ->
      with %CaptureRun{} = run <- locked_run_by_id(run.id),
           %CaptureObservation{status: :running} = observation <-
             locked_observation(run.id, observation.id),
           %ProviderAttempt{status: :started} = attempt <- locked_attempt(attempt.id) do
        now = DateTime.utc_now()

        attempt
        |> ProviderAttempt.result_changeset(%{
          status: :succeeded,
          provider_request_id: result.request_id,
          retryable: false,
          latency_ms: result.latency_ms,
          finished_at: now
        })
        |> Repo.update!()

        observation
        |> CaptureObservation.lifecycle_changeset(%{
          status: :succeeded,
          requested_model: result.requested_model,
          returned_model: result.returned_model,
          output_text: result.output_text,
          completion_state: result.completion_state,
          finish_reason: result.finish_reason,
          input_tokens: result.input_tokens,
          output_tokens: result.output_tokens,
          latency_ms: result.latency_ms,
          provider_request_id: result.request_id,
          provider_metadata: result.metadata,
          captured_at: result.captured_at,
          terminal_at: now
        })
        |> Repo.update!()
      else
        _other -> Repo.rollback(:attempt_no_longer_active)
      end
    end)
    |> unwrap_transaction()
  end

  defp persist_failure(run, observation, attempt, failure) do
    Repo.transaction(fn ->
      with %CaptureRun{} = run <- locked_run_by_id(run.id),
           %CaptureObservation{status: :running} = observation <-
             locked_observation(run.id, observation.id),
           %ProviderAttempt{status: :started} = attempt <- locked_attempt(attempt.id) do
        now = DateTime.utc_now()
        category = failure_category(failure.category)
        latency_ms = failure.latency_ms || 0

        attempt
        |> ProviderAttempt.result_changeset(%{
          status: :failed,
          provider_request_id: failure.request_id,
          retryable: failure.retryable,
          failure_category: category,
          failure_message: failure.message,
          latency_ms: latency_ms,
          finished_at: now
        })
        |> Repo.update!()

        if retry_allowed?(run, attempt, failure) do
          observation
          |> CaptureObservation.lifecycle_changeset(%{
            status: :retrying,
            requested_model: run.requested_model,
            returned_model: failure.returned_model,
            provider_request_id: failure.request_id,
            provider_metadata: failure.metadata
          })
          |> Repo.update!()

          {:retry, retry_delay(attempt.attempt_number)}
        else
          observation
          |> CaptureObservation.lifecycle_changeset(%{
            status: :failed,
            requested_model: run.requested_model,
            returned_model: failure.returned_model,
            latency_ms: latency_ms,
            provider_request_id: failure.request_id,
            failure_category: category,
            failure_message: failure.message,
            provider_metadata: failure.metadata,
            terminal_at: now
          })
          |> Repo.update!()

          finalize_run!(run)
          :ok
        end
      else
        _other -> Repo.rollback(:attempt_no_longer_active)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, :attempt_no_longer_active} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_allowed?(run, attempt, failure) do
    failure.retryable and is_nil(run.cancellation_requested_at) and
      attempt.attempt_number <= run.retry_limit and
      attempt_count(run.id) < run.maximum_call_count
  end

  defp ensure_evaluation_and_finalize(run, observation) do
    with {:ok, _evaluation} <- ensure_evaluation(run.id, observation.id),
         {:ok, _run} <- finalize_run(run.id) do
      :ok
    end
  end

  defp ensure_evaluation(run_id, observation_id) do
    Repo.transaction(fn ->
      with %CaptureRun{} = run <- locked_run_by_id(run_id),
           %CaptureObservation{status: :succeeded} = observation <-
             locked_observation(run.id, observation_id),
           %ContractVersion{} = contract_version <-
             Repo.get(ContractVersion, run.contract_version_id) do
        case EvaluationPersistence.ensure(
               observation,
               contract_version,
               run.evaluator_engine_version
             ) do
          {:ok, evaluation} -> evaluation
          {:error, reason} -> Repo.rollback({:evaluation_failed, reason})
        end
      else
        nil -> Repo.rollback(:not_found)
        %CaptureObservation{} -> Repo.rollback(:observation_not_successful)
      end
    end)
    |> unwrap_transaction()
  end

  defp finalize_run(run_id) do
    Repo.transaction(fn ->
      case locked_run_by_id(run_id) do
        %CaptureRun{} = run -> finalize_run!(run)
        nil -> Repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  defp finalize_run!(%CaptureRun{status: status} = run) when status in @terminal_run_statuses,
    do: run

  defp finalize_run!(run) do
    counts = observation_counts(run.id)
    active_count = count_statuses(counts, [:planned, :running, :retrying])
    success_count = Map.get(counts, :succeeded, 0)
    evaluation_count = evaluation_count(run.id, run.evaluator_engine_version)

    if active_count > 0 or evaluation_count < success_count do
      run
    else
      status = terminal_run_status(run, counts)

      run
      |> CaptureRun.lifecycle_changeset(%{
        status: status,
        completed_at: DateTime.utc_now()
      })
      |> Repo.update!()
    end
  end

  defp terminal_run_status(run, counts) do
    success_count = Map.get(counts, :succeeded, 0)
    unknown_count = Map.get(counts, :unknown, 0)
    total_count = Enum.sum(Map.values(counts))

    cond do
      not is_nil(run.cancellation_requested_at) -> :cancelled
      unknown_count > 0 -> :needs_review
      success_count == total_count -> :succeeded
      success_count > 0 -> :partial_failed
      true -> :failed
    end
  end

  defp cancel_run_transaction(workspace_id, run_id) do
    Repo.transaction(fn ->
      case locked_run(workspace_id, run_id) do
        %CaptureRun{status: status} = run when status in @terminal_run_statuses ->
          run

        %CaptureRun{} = run ->
          now = DateTime.utc_now()

          CaptureObservation
          |> where(
            [observation],
            observation.capture_run_id == ^run.id and
              observation.status in [:planned, :retrying]
          )
          |> Repo.update_all(set: [status: :cancelled, terminal_at: now, updated_at: now])

          run =
            run
            |> CaptureRun.lifecycle_changeset(%{cancellation_requested_at: now})
            |> Repo.update!()

          finalize_run!(run)

        nil ->
          Repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  defp cancel_queued_jobs(run_id) do
    ObservationWorker
    |> to_string()
    |> then(fn worker ->
      Oban.Job
      |> where(
        [job],
        job.worker == ^worker and job.state in ["available", "scheduled", "retryable"] and
          fragment("?->>'capture_run_id' = ?", job.args, ^run_id)
      )
      |> Oban.cancel_all_jobs()
    end)

    :ok
  end

  defp fail_without_attempt!(run, observation, category, message) do
    now = DateTime.utc_now()

    observation
    |> CaptureObservation.lifecycle_changeset(%{
      status: :failed,
      requested_model: run.requested_model,
      failure_category: category,
      failure_message: message,
      terminal_at: now
    })
    |> Repo.update!()

    finalize_run!(run)
    :done
  end

  defp cancel_observation!(observation) do
    observation
    |> CaptureObservation.lifecycle_changeset(%{
      status: :cancelled,
      terminal_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp ensure_run_started!(%CaptureRun{status: status} = run)
       when status in [:planned, :queued] do
    run
    |> CaptureRun.lifecycle_changeset(%{
      status: :running,
      started_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp ensure_run_started!(run), do: run

  defp failure_category(category)
       when category in [
              :authentication,
              :authorization,
              :rate_limited,
              :invalid_request,
              :request_too_large,
              :timeout,
              :transport,
              :provider_unavailable,
              :malformed_response,
              :model_mismatch,
              :call_cap_exceeded,
              :credential_unavailable,
              :unknown_outcome
            ],
       do: category

  defp failure_category(_category), do: :provider_unavailable

  defp retry_delay(attempt_number), do: min(Integer.pow(2, attempt_number - 1), 60)

  defp observation_counts(run_id) do
    CaptureObservation
    |> where([observation], observation.capture_run_id == ^run_id)
    |> group_by([observation], observation.status)
    |> select([observation], {observation.status, count(observation.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp count_statuses(counts, statuses) do
    Enum.reduce(statuses, 0, &(Map.get(counts, &1, 0) + &2))
  end

  defp evaluation_count(run_id, evaluator_engine_version) do
    CaptureEvaluation
    |> join(:inner, [evaluation], observation in CaptureObservation,
      on: observation.id == evaluation.capture_observation_id
    )
    |> where(
      [evaluation, observation],
      observation.capture_run_id == ^run_id and
        evaluation.evaluator_engine_version == ^evaluator_engine_version
    )
    |> Repo.aggregate(:count)
  end

  defp attempt_count(run_id) do
    ProviderAttempt
    |> where([attempt], attempt.capture_run_id == ^run_id)
    |> Repo.aggregate(:count)
  end

  defp observation_attempt_count(observation_id) do
    ProviderAttempt
    |> where([attempt], attempt.capture_observation_id == ^observation_id)
    |> Repo.aggregate(:count)
  end

  defp started_attempt(observation_id) do
    ProviderAttempt
    |> where(
      [attempt],
      attempt.capture_observation_id == ^observation_id and attempt.status == :started
    )
    |> order_by([attempt], desc: attempt.attempt_number)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_attempt(attempt_id) do
    ProviderAttempt
    |> where([attempt], attempt.id == ^attempt_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_observation(run_id, observation_id) do
    CaptureObservation
    |> where(
      [observation],
      observation.capture_run_id == ^run_id and observation.id == ^observation_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_observations(run_id) do
    CaptureObservation
    |> where([observation], observation.capture_run_id == ^run_id)
    |> order_by([observation], asc: observation.sample_index, asc: observation.id)
    |> Repo.all()
  end

  defp preload_run(run) do
    Repo.preload(run,
      observations: [
        provider_attempts: from(attempt in ProviderAttempt, order_by: attempt.attempt_number),
        evaluations: [
          rule_results: from(result in CaptureRuleResult, order_by: result.position)
        ]
      ]
    )
  end

  defp active_monitor_version(%Monitor{active_version_id: nil}), do: nil

  defp active_monitor_version(monitor) do
    MonitorVersion
    |> where(
      [version],
      version.id == ^monitor.active_version_id and version.monitor_id == ^monitor.id and
        version.status == :active
    )
    |> preload(:cases)
    |> Repo.one()
  end

  defp approved_contract(monitor_id, monitor_version_id) do
    ContractVersion
    |> where(
      [contract],
      contract.monitor_id == ^monitor_id and
        contract.monitor_version_id == ^monitor_version_id and contract.status == :approved
    )
    |> Repo.one()
  end

  defp valid_credential(%Monitor{provider_credential_id: nil}, _provider), do: nil

  defp valid_credential(monitor, provider) do
    ProviderCredential
    |> where(
      [credential],
      credential.id == ^monitor.provider_credential_id and
        credential.workspace_id == ^monitor.workspace_id and credential.provider == ^provider and
        credential.status == :valid
    )
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

  defp monitor_in_workspace?(workspace_id, monitor_id) do
    Monitor
    |> where(
      [monitor],
      monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id
    )
    |> Repo.exists?()
  end

  defp active_run_for_monitor(monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.monitor_id == ^monitor_id and run.status in [:planned, :queued, :running]
    )
    |> order_by([run], asc: run.inserted_at, asc: run.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp cancel_active_monitor_runs(workspace_id, monitor_id) do
    run_ids =
      CaptureRun
      |> where(
        [run],
        run.workspace_id == ^workspace_id and run.monitor_id == ^monitor_id and
          run.status in [:planned, :queued, :running]
      )
      |> select([run], run.id)
      |> Repo.all()

    Enum.flat_map(run_ids, fn run_id ->
      case cancel_run_transaction(workspace_id, run_id) do
        {:ok, run} ->
          cancel_queued_jobs(run.id)
          [run]

        {:error, _reason} ->
          []
      end
    end)
  end

  defp run_by_identity(workspace_id, identity_key, options) do
    query =
      CaptureRun
      |> where(
        [run],
        run.workspace_id == ^workspace_id and run.identity_key == ^identity_key
      )

    query = if options[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp locked_run(workspace_id, run_id) do
    CaptureRun
    |> where([run], run.workspace_id == ^workspace_id and run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_run_by_id(run_id) do
    CaptureRun
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_run(workspace_id, run_id) do
    CaptureRun
    |> where([run], run.workspace_id == ^workspace_id and run.id == ^run_id)
    |> Repo.one()
  end

  defp identity_key(value) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and value != "" and byte_size(value) <= 200,
      do: {:ok, value},
      else: {:error, :invalid_identity_key}
  end

  defp identity_key(_value), do: {:error, :invalid_identity_key}

  defp run_kind(value) when value in [:baseline, "baseline"], do: {:ok, :baseline}
  defp run_kind(value) when value in [:manual, "manual"], do: {:ok, :manual}
  defp run_kind(value) when value in [:scheduled, "scheduled"], do: {:ok, :scheduled}
  defp run_kind(_value), do: {:error, :invalid_run_kind}

  defp bounded_integer(value, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: {:ok, value}

  defp bounded_integer(value, minimum, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> bounded_integer(parsed, minimum, maximum)
      _other -> {:error, :invalid_run_plan}
    end
  end

  defp bounded_integer(_value, _minimum, _maximum), do: {:error, :invalid_run_plan}

  defp capture_limit(key) do
    :silent_regression
    |> Application.fetch_env!(:capture_domain)
    |> Keyword.fetch!(key)
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
