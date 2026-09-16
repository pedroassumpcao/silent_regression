defmodule SilentRegression.Reviews do
  @moduledoc """
  Workspace-scoped, append-only human review evidence.

  The server derives every run, contract, baseline, evaluation, and rule identity from the selected
  alert or observation. Clients submit only the subject, judgment, action, and expected chain leaf.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit
  alias SilentRegression.ContractAuthoring

  alias SilentRegression.Captures.{
    CaptureEvaluation,
    CaptureObservation,
    CaptureRuleResult,
    CaptureRun
  }

  alias SilentRegression.Repo
  alias SilentRegression.Reviews.{ContractRevisionOrigin, ReviewDecision}
  alias SilentRegression.RunResults.Alert
  alias SilentRegression.Workspaces.{Membership, Workspace}

  def submit_review(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = reviewer
        },
        attrs
      )
      when is_map(attrs) do
    with {:ok, subject_kind} <- subject_kind(value(attrs, :subject_kind)),
         {:ok, subject_id} <- Ecto.UUID.cast(value(attrs, :subject_id)) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- load_evidence(workspace_id, subject_kind, subject_id, attrs),
             decisions <- locked_chain(workspace_id, evidence.review_key),
             current <- current_decision(decisions),
             :ok <- ensure_expected_current(current, value(attrs, :expected_current_id)),
             attrs <- normalize_attrs(attrs),
             evidence <- Map.put(evidence, :supersedes_id, current && current.id),
             {:ok, decision} <-
               %ReviewDecision{}
               |> ReviewDecision.create_changeset(evidence, reviewer, attrs)
               |> Repo.insert() do
          record_review!(decision, reviewer)
          Repo.preload(decision, :reviewer_user)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def submit_review(%Scope{}, _attrs), do: {:error, :workspace_required}

  def list_run_reviews(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        run_id
      ) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id),
         true <- run_exists?(workspace_id, run_id) do
      decisions =
        ReviewDecision
        |> where(
          [decision],
          decision.workspace_id == ^workspace_id and decision.capture_run_id == ^run_id
        )
        |> order_by([decision], asc: decision.reviewed_at, asc: decision.id)
        |> preload(:reviewer_user)
        |> Repo.all()

      {:ok, %{decisions: mark_current(decisions), summary: summarize(decisions)}}
    else
      _reason -> {:error, :not_found}
    end
  end

  def list_run_reviews(%Scope{}, _run_id), do: {:error, :workspace_required}

  @doc false
  def current_for_alert(workspace_id, alert_id)
      when is_binary(workspace_id) and is_binary(alert_id) do
    workspace_id
    |> chain_query(review_key(:alert, alert_id))
    |> Repo.all()
    |> current_decision()
  end

  @doc false
  def locked_current_for_alert(workspace_id, alert_id)
      when is_binary(workspace_id) and is_binary(alert_id) do
    workspace_id
    |> locked_chain(review_key(:alert, alert_id))
    |> current_decision()
  end

  def start_contract_revision(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = actor
        } = scope,
        review_id
      ) do
    with {:ok, review_id} <- Ecto.UUID.cast(review_id) do
      Repo.transaction(fn ->
        with %ReviewDecision{} = decision <- locked_review(workspace_id, review_id),
             :ok <- ensure_current(decision),
             :ok <- ensure_contract_action(decision),
             {:ok, contract_version} <-
               ContractAuthoring.create_revision(scope, decision.monitor_id),
             {:ok, origin} <- insert_revision_origin(decision, contract_version, actor) do
          record_revision_origin!(origin, decision, actor)
          %{origin: origin, contract_version: contract_version}
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def start_contract_revision(%Scope{}, _review_id), do: {:error, :workspace_required}

  def list_contract_revision_origins(contract_version_id) when is_binary(contract_version_id) do
    ContractRevisionOrigin
    |> where([origin], origin.contract_version_id == ^contract_version_id)
    |> order_by([origin], asc: origin.inserted_at, asc: origin.id)
    |> preload([:actor_user, :review_decision])
    |> Repo.all()
  end

  def get_review(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        review_id
      ) do
    with {:ok, review_id} <- Ecto.UUID.cast(review_id),
         %ReviewDecision{} = decision <-
           Repo.get_by(ReviewDecision, id: review_id, workspace_id: workspace_id) do
      {:ok, Repo.preload(decision, :reviewer_user)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_review(%Scope{}, _review_id), do: {:error, :workspace_required}

  def current?(%ReviewDecision{} = decision) do
    not Repo.exists?(
      from successor in ReviewDecision,
        where: successor.supersedes_id == ^decision.id
    )
  end

  defp load_evidence(workspace_id, :alert, alert_id, attrs) do
    alert =
      Alert
      |> where([alert], alert.workspace_id == ^workspace_id and alert.id == ^alert_id)
      |> preload([:capture_run, capture_evaluation: :rule_results])
      |> Repo.one()

    case alert do
      %Alert{} ->
        with {:ok, rule_result_id} <-
               selected_rule_result_id(alert.capture_evaluation, value(attrs, :rule_result_id)) do
          {:ok,
           evidence(alert.capture_run, %{
             review_key: review_key(:alert, alert.id),
             subject_kind: :alert,
             result_alert_id: alert.id,
             capture_observation_id: nil,
             capture_evaluation_id: alert.capture_evaluation_id,
             capture_rule_result_id: rule_result_id
           })}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp load_evidence(workspace_id, :observation, observation_id, attrs) do
    observation =
      CaptureObservation
      |> join(:inner, [observation], run in CaptureRun, on: run.id == observation.capture_run_id)
      |> where(
        [observation, run],
        run.workspace_id == ^workspace_id and observation.id == ^observation_id
      )
      |> preload([_observation, run], capture_run: run)
      |> Repo.one()

    case observation do
      %CaptureObservation{capture_run: run} ->
        evaluation = exact_run_evaluation(observation.id, run)

        with {:ok, rule_result_id} <-
               selected_rule_result_id(evaluation, value(attrs, :rule_result_id)) do
          {:ok,
           evidence(run, %{
             review_key: review_key(:observation, observation.id),
             subject_kind: :observation,
             result_alert_id: nil,
             capture_observation_id: observation.id,
             capture_evaluation_id: evaluation && evaluation.id,
             capture_rule_result_id: rule_result_id
           })}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp evidence(run, subject) do
    Map.merge(subject, %{
      workspace_id: run.workspace_id,
      monitor_id: run.monitor_id,
      capture_run_id: run.id,
      contract_version_id: run.contract_version_id,
      baseline_snapshot_id: run.baseline_snapshot_id
    })
  end

  defp exact_run_evaluation(observation_id, run) do
    CaptureEvaluation
    |> where(
      [evaluation],
      evaluation.capture_observation_id == ^observation_id and
        evaluation.contract_version_id == ^run.contract_version_id and
        evaluation.evaluator_engine_version == ^run.evaluator_engine_version
    )
    |> preload(:rule_results)
    |> Repo.one()
  end

  defp selected_rule_result_id(_evaluation, value) when value in [nil, ""], do: {:ok, nil}

  defp selected_rule_result_id(%CaptureEvaluation{} = evaluation, value) do
    with {:ok, rule_result_id} <- Ecto.UUID.cast(value),
         %CaptureRuleResult{} <-
           Enum.find(evaluation.rule_results, &(&1.id == rule_result_id)) do
      {:ok, rule_result_id}
    else
      _reason -> {:error, :not_found}
    end
  end

  defp selected_rule_result_id(nil, _value), do: {:error, :not_found}

  defp locked_chain(workspace_id, review_key) do
    workspace_id
    |> chain_query(review_key)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp locked_review(workspace_id, review_id) do
    ReviewDecision
    |> where(
      [decision],
      decision.workspace_id == ^workspace_id and decision.id == ^review_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp chain_query(workspace_id, review_key) do
    ReviewDecision
    |> where(
      [decision],
      decision.workspace_id == ^workspace_id and decision.review_key == ^review_key
    )
    |> order_by([decision], asc: decision.reviewed_at, asc: decision.id)
  end

  defp current_decision([]), do: nil

  defp current_decision(decisions) do
    superseded_ids = MapSet.new(decisions, & &1.supersedes_id)
    Enum.find(decisions, &(not MapSet.member?(superseded_ids, &1.id)))
  end

  defp ensure_expected_current(nil, value) when value in [nil, ""], do: :ok
  defp ensure_expected_current(%ReviewDecision{id: id}, id), do: :ok
  defp ensure_expected_current(_current, _expected), do: {:error, :stale_review}

  defp ensure_current(decision) do
    if current?(decision), do: :ok, else: {:error, :stale_review}
  end

  defp ensure_contract_action(%ReviewDecision{action: :contract_revision}), do: :ok
  defp ensure_contract_action(%ReviewDecision{}), do: {:error, :contract_action_required}

  defp insert_revision_origin(decision, contract_version, actor) do
    case Repo.get_by(ContractRevisionOrigin, review_decision_id: decision.id) do
      %ContractRevisionOrigin{} = origin ->
        {:ok, origin}

      nil ->
        %ContractRevisionOrigin{}
        |> ContractRevisionOrigin.create_changeset(decision, contract_version, actor)
        |> Repo.insert()
    end
  end

  defp normalize_attrs(attrs) do
    %{
      classification: value(attrs, :classification),
      action: value(attrs, :action, "none"),
      rationale: normalize_rationale(value(attrs, :rationale)),
      reviewed_at: DateTime.utc_now()
    }
  end

  defp normalize_rationale(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      rationale -> rationale
    end
  end

  defp normalize_rationale(_value), do: nil

  defp mark_current(decisions) do
    current = current_decision(decisions)
    Enum.map(decisions, &%{decision: &1, current?: not is_nil(current) and &1.id == current.id})
  end

  defp summarize(decisions) do
    grouped = Enum.group_by(decisions, & &1.review_key)
    current = grouped |> Map.values() |> Enum.map(&current_decision/1) |> Enum.reject(&is_nil/1)

    %{
      current_count: length(current),
      classification_counts: Enum.frequencies_by(current, & &1.classification),
      action_counts: Enum.frequencies_by(current, & &1.action),
      changed_judgment_count:
        Enum.count(grouped, fn {_key, history} ->
          history |> Enum.map(& &1.classification) |> Enum.uniq() |> length() > 1
        end),
      superseded_count: max(length(decisions) - length(current), 0)
    }
  end

  defp record_review!(decision, reviewer) do
    Audit.record_event!(%{
      action: "review_decision.recorded",
      target_type: "review_decision",
      target_id: decision.id,
      workspace_id: decision.workspace_id,
      actor_user_id: reviewer.id,
      metadata: %{
        "action" => Atom.to_string(decision.action),
        "capture_run_id" => decision.capture_run_id,
        "classification" => Atom.to_string(decision.classification),
        "review_key" => decision.review_key,
        "supersedes_id" => decision.supersedes_id
      }
    })
  end

  defp record_revision_origin!(origin, decision, actor) do
    Audit.record_event!(%{
      action: "review_decision.contract_revision_started",
      target_type: "review_decision",
      target_id: decision.id,
      workspace_id: decision.workspace_id,
      actor_user_id: actor.id,
      metadata: %{
        "contract_version_id" => origin.contract_version_id,
        "origin_id" => origin.id
      }
    })
  end

  defp review_key(kind, id), do: "#{kind}:#{id}"

  defp subject_kind(value) when value in [:alert, "alert"], do: {:ok, :alert}
  defp subject_kind(value) when value in [:observation, "observation"], do: {:ok, :observation}
  defp subject_kind(_value), do: {:error, :invalid_subject}

  defp run_exists?(workspace_id, run_id) do
    Repo.exists?(
      from run in CaptureRun,
        where: run.workspace_id == ^workspace_id and run.id == ^run_id
    )
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
