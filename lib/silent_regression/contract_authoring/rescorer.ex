defmodule SilentRegression.ContractAuthoring.Rescorer do
  @moduledoc """
  Pins and deterministically rescores historical outputs in durable batches.

  A successor remains inactive while this work runs. Only a successful final
  transaction retires the predecessor and activates the candidate.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.User
  alias SilentRegression.Audit
  alias SilentRegression.Captures.{CaptureObservation, CaptureRun, EvaluationPersistence}

  alias SilentRegression.ContractAuthoring.{
    ContractVersion,
    RescoreItem,
    RescoreRun,
    RescoreSummary
  }

  alias SilentRegression.ContractAuthoring.Workers.RescoreWorker
  alias SilentRegression.Repo

  @batch_size 50
  @snapshot_insert_batch_size 500

  def batch_size, do: @batch_size

  def successful_observation_ids(monitor_id) do
    CaptureObservation
    |> join(:inner, [observation], run in CaptureRun, on: run.id == observation.capture_run_id)
    |> where(
      [observation, run],
      run.monitor_id == ^monitor_id and observation.status == :succeeded
    )
    |> order_by([observation, run], asc: run.inserted_at, asc: observation.id)
    |> select([observation], observation.id)
    |> Repo.all()
  end

  def create_empty_summary(contract_version, predecessor) do
    %RescoreSummary{}
    |> RescoreSummary.create_changeset(contract_version, predecessor, %{
      observation_count: 0,
      pass_count: 0,
      fail_count: 0,
      evaluator_error_count: 0,
      interpretation_changed: interpretation_changed?(contract_version, predecessor),
      rescored_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  def create_run(contract_version, predecessor, user, observation_ids)
      when is_list(observation_ids) and observation_ids != [] do
    now = DateTime.utc_now()

    with {:ok, run} <-
           %RescoreRun{}
           |> RescoreRun.create_changeset(contract_version, predecessor, user, %{
             batch_size: @batch_size,
             total_count: length(observation_ids),
             requested_at: now
           })
           |> Repo.insert(),
         :ok <- insert_items(run, observation_ids, now),
         {:ok, _job} <- enqueue(run.id, 0) do
      {:ok, run}
    end
  end

  def process_batch(run_id) do
    case Repo.transaction(fn -> process_locked_run(run_id) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def fail_infrastructure(run_id, reason) do
    Repo.transaction(fn ->
      case locked_run(run_id) do
        %RescoreRun{status: status} when status in [:succeeded, :failed] ->
          :ok

        %RescoreRun{} = run ->
          candidate = Repo.get!(ContractVersion, run.contract_version_id)
          now = DateTime.utc_now()
          error = failure_error("rescore_worker_exhausted", nil, reason)

          run
          |> RescoreRun.failed_changeset(counts(run), error, now)
          |> Repo.update!()

          candidate
          |> ContractVersion.rescore_failed_changeset()
          |> Repo.update!()

          record_failure!(candidate, run, error)
          :ok

        nil ->
          :ok
      end
    end)
  end

  defp process_locked_run(run_id) do
    case locked_run(run_id) do
      nil ->
        :discard

      %RescoreRun{status: status} when status in [:succeeded, :failed] ->
        :complete

      %RescoreRun{} = run ->
        run = ensure_running!(run)
        candidate = Repo.get!(ContractVersion, run.contract_version_id)
        items = pending_items(run)

        case evaluate_items(items, candidate, counts(run)) do
          {:ok, updated_counts} ->
            continue_or_activate!(run, candidate, updated_counts)

          {:error, item, evaluation, error, updated_counts} ->
            fail_evaluation!(run, candidate, item, evaluation, error, updated_counts)
        end
    end
  end

  defp evaluate_items(items, contract_version, initial_counts) do
    Enum.reduce_while(items, {:ok, initial_counts}, fn item, {:ok, counts} ->
      observation = Repo.get!(CaptureObservation, item.capture_observation_id)
      now = DateTime.utc_now()

      case EvaluationPersistence.ensure(
             observation,
             contract_version,
             contract_version.evaluator_engine_version
           ) do
        {:ok, %{status: :evaluator_error} = evaluation} ->
          error = failure_error("historical_evaluator_error", observation.id, evaluation.error)
          updated_counts = increment(counts, :evaluator_error_count)
          {:halt, {:error, item, evaluation, error, updated_counts}}

        {:ok, evaluation} ->
          item
          |> RescoreItem.success_changeset(evaluation, now)
          |> Repo.update!()

          {:cont, {:ok, increment(counts, count_key(evaluation.status))}}

        {:error, reason} ->
          error = failure_error("historical_rescore_failed", observation.id, reason)
          updated_counts = increment(counts, :evaluator_error_count)
          {:halt, {:error, item, nil, error, updated_counts}}
      end
    end)
  end

  defp continue_or_activate!(run, candidate, updated_counts) do
    if updated_counts.processed_count == run.total_count do
      activate!(run, candidate, updated_counts)
    else
      run
      |> RescoreRun.progress_changeset(updated_counts)
      |> Repo.update!()

      {:ok, _job} = enqueue(run.id, updated_counts.processed_count)
      :continue
    end
  end

  defp activate!(run, candidate, updated_counts) do
    requester = Repo.get(User, run.requested_by_user_id)

    if requester do
      predecessor = locked_contract(run.predecessor_contract_version_id)
      now = DateTime.utc_now()

      %RescoreSummary{}
      |> RescoreSummary.create_changeset(candidate, predecessor, %{
        observation_count: run.total_count,
        pass_count: updated_counts.pass_count,
        fail_count: updated_counts.fail_count,
        evaluator_error_count: updated_counts.evaluator_error_count,
        interpretation_changed: interpretation_changed?(candidate, predecessor),
        rescored_at: now
      })
      |> Repo.insert!()

      retire_predecessor!(predecessor, now)

      approved =
        candidate
        |> ContractVersion.approve_changeset(requester, DateTime.truncate(now, :second), %{})
        |> Repo.update!()

      run
      |> RescoreRun.succeeded_changeset(updated_counts, now)
      |> Repo.update!()

      record_approval!(approved, run, updated_counts)
      :activated
    else
      error = failure_error("approval_requester_unavailable", nil, :user_not_found)
      fail_run!(run, candidate, updated_counts, error)
    end
  end

  defp fail_evaluation!(run, candidate, item, evaluation, error, updated_counts) do
    now = DateTime.utc_now()

    item
    |> RescoreItem.evaluator_error_changeset(evaluation, error, now)
    |> Repo.update!()

    fail_run!(run, candidate, updated_counts, error)
  end

  defp fail_run!(run, candidate, updated_counts, error) do
    now = DateTime.utc_now()

    run
    |> RescoreRun.failed_changeset(updated_counts, error, now)
    |> Repo.update!()

    candidate
    |> ContractVersion.rescore_failed_changeset()
    |> Repo.update!()

    record_failure!(candidate, run, error)
    :failed
  end

  defp ensure_running!(%RescoreRun{status: :pending} = run) do
    run
    |> RescoreRun.running_changeset(DateTime.utc_now())
    |> Repo.update!()
  end

  defp ensure_running!(%RescoreRun{status: :running} = run), do: run

  defp pending_items(run) do
    RescoreItem
    |> where(
      [item],
      item.contract_rescore_run_id == ^run.id and item.status == :pending
    )
    |> order_by([item], asc: item.position)
    |> limit(^run.batch_size)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp locked_run(run_id) do
    RescoreRun
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_contract(nil), do: nil

  defp locked_contract(contract_version_id) do
    ContractVersion
    |> where([contract], contract.id == ^contract_version_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp retire_predecessor!(nil, _at), do: :ok

  defp retire_predecessor!(predecessor, at) do
    predecessor
    |> ContractVersion.retire_changeset(DateTime.truncate(at, :second))
    |> Repo.update!()
  end

  defp insert_items(run, observation_ids, now) do
    entries =
      observation_ids
      |> Enum.with_index()
      |> Enum.map(fn {observation_id, position} ->
        %{
          id: Ecto.UUID.generate(),
          contract_rescore_run_id: run.id,
          capture_observation_id: observation_id,
          position: position,
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)

    inserted_count =
      entries
      |> Enum.chunk_every(@snapshot_insert_batch_size)
      |> Enum.reduce(0, fn batch, count ->
        {batch_count, nil} = Repo.insert_all(RescoreItem, batch)
        count + batch_count
      end)

    if inserted_count == length(observation_ids),
      do: :ok,
      else: {:error, :rescore_item_snapshot_incomplete}
  end

  defp enqueue(run_id, generation) do
    %{rescore_run_id: run_id, generation: generation}
    |> RescoreWorker.new()
    |> Oban.insert()
  end

  defp counts(run) do
    %{
      processed_count: run.processed_count,
      pass_count: run.pass_count,
      fail_count: run.fail_count,
      evaluator_error_count: run.evaluator_error_count
    }
  end

  defp increment(counts, key) do
    counts
    |> Map.update!(:processed_count, &(&1 + 1))
    |> Map.update!(key, &(&1 + 1))
  end

  defp count_key(:pass), do: :pass_count
  defp count_key(:fail), do: :fail_count

  defp interpretation_changed?(_contract_version, nil), do: true

  defp interpretation_changed?(contract_version, predecessor) do
    contract_version.contract_fingerprint != predecessor.contract_fingerprint or
      contract_version.evaluator_engine_version != predecessor.evaluator_engine_version
  end

  defp failure_error(code, observation_id, reason) do
    %{
      "code" => code,
      "observation_id" => observation_id,
      "reason_code" => reason_code(reason)
    }
  end

  defp reason_code(%{"code" => code}) when is_binary(code), do: String.slice(code, 0, 120)
  defp reason_code(%{code: code}) when is_binary(code), do: String.slice(code, 0, 120)
  defp reason_code(%Ecto.Changeset{}), do: "persistence_validation_failed"
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "unclassified_failure"

  defp record_approval!(contract_version, run, counts) do
    Audit.record_event!(%{
      action: "contract_version.approved",
      target_type: "contract_version",
      target_id: contract_version.id,
      workspace_id: contract_version.workspace_id,
      actor_user_id: run.requested_by_user_id,
      metadata:
        contract_metadata(contract_version)
        |> Map.merge(%{
          "fixture_count" => Repo.aggregate(Ecto.assoc(contract_version, :fixtures), :count),
          "rescore_observation_count" => run.total_count,
          "rescore_pass_count" => counts.pass_count,
          "rescore_fail_count" => counts.fail_count,
          "interpretation_changed" =>
            interpretation_changed?(
              contract_version,
              Repo.get(ContractVersion, run.predecessor_contract_version_id)
            ),
          "proof_schema_version" => contract_version.proof_schema_version,
          "proof_fingerprint" => contract_version.proof_fingerprint,
          "coverage_waiver_count" =>
            Repo.aggregate(Ecto.assoc(contract_version, :coverage_waivers), :count)
        })
    })
  end

  defp record_failure!(contract_version, run, error) do
    Audit.record_event!(%{
      action: "contract_version.rescore_failed",
      target_type: "contract_version",
      target_id: contract_version.id,
      workspace_id: contract_version.workspace_id,
      actor_user_id: run.requested_by_user_id,
      metadata:
        contract_metadata(contract_version)
        |> Map.put("status", "rescore_failed")
        |> Map.merge(%{
          "rescore_run_id" => run.id,
          "error_code" => error["code"],
          "observation_id" => error["observation_id"]
        })
    })
  end

  defp contract_metadata(contract_version) do
    %{
      "monitor_id" => contract_version.monitor_id,
      "version" => contract_version.version,
      "status" => Atom.to_string(contract_version.status),
      "template_key" => contract_version.template_key,
      "assistance_mode" => Atom.to_string(contract_version.assistance_mode),
      "fingerprint" => contract_version.fingerprint
    }
  end
end
