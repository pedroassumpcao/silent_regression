defmodule SilentRegression.GuidedSetups.FirstRun do
  @moduledoc "Coordinates existing first-capture boundaries without authorizing work on reads."
  import Ecto.Query
  alias SilentRegression.Accounts.Scope
  alias SilentRegression.{Baselines, ContractAuthoring, MonitorOperations, ProductAnalytics, Repo}
  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.GuidedSetups.{Draft, Recipes}
  alias SilentRegression.Monitors.{Fingerprint, Monitor}
  alias SilentRegression.ProductAnalytics.ProductEvent
  alias SilentRegression.Workspaces.{Membership, Workspace}

  def get_state(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}} = scope,
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Draft{} = draft <-
           Repo.get_by(Draft, workspace_id: workspace_id, monitor_id: monitor_id),
         {:ok, contract} <- ContractAuthoring.get_state(scope, monitor_id),
         {:ok, baseline} <- Baselines.get_state(scope, monitor_id),
         {:ok, compiled} <- Recipes.compile(draft) do
      snapshot = baseline.snapshot
      current = contract.contract_version
      # Guided evidence describes the original recipe. Later advanced changes must not be
      # presented as though the original synthetic review approved them.
      original? =
        contract.monitor_version.version == 1 and not is_nil(current) and
          current.root == compiled.root

      fingerprint = review_fingerprint(snapshot)

      {:ok,
       %{
         draft: draft,
         contract: contract,
         baseline: baseline,
         compiled: compiled,
         original?: original?,
         review_fingerprint: fingerprint,
         reviewed?: reviewed?(scope, monitor_id, fingerprint),
         completed?:
           original? and not is_nil(snapshot) and snapshot.status == :approved and
             baseline.compatibility.compatible? and contract.monitor.state in [:active, :paused],
         can_finish?:
           original? and not is_nil(snapshot) and snapshot.status in [:pending, :approved] and
             baseline.health.normal_approvable? and baseline.compatibility.compatible?
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_state(%Scope{}, _monitor_id), do: {:error, :not_found}

  def corrected_draft(scope, monitor_id) do
    with {:ok, state} <- get_state(scope, monitor_id) do
      Repo.transaction(fn ->
        draft = unwrap!(SilentRegression.GuidedSetups.create(scope, state.draft.recipe))

        unwrap!(
          SilentRegression.GuidedSetups.save(scope, draft.id, draft.revision, state.draft.raw)
        )
      end)
    end
  end

  def approve_checks(scope, monitor_id, identity) when is_map(identity) do
    owner_transaction(scope, monitor_id, fn state ->
      ensure_original!(state)
      unwrap!(ContractAuthoring.approve(scope, monitor_id, identity))
    end)
  end

  def approve_checks(_scope, _monitor_id, _identity), do: {:error, :stale_review}

  def validate_model(scope, monitor_id) do
    with :ok <- owner(scope), {:ok, _} <- get_state(scope, monitor_id) do
      Baselines.validate_model_access(scope, monitor_id)
    end
  end

  def authorize(scope, monitor_id, attrs) when is_map(attrs) do
    owner_transaction(scope, monitor_id, fn state ->
      ensure_original!(state)
      if attrs["confirmed"] != true, do: Repo.rollback(:authorization_required)
      snapshot = state.baseline.snapshot

      if snapshot && snapshot.preview_fingerprint == attrs["preview_fingerprint"] do
        # Refreshes and duplicate submissions resume the durable attempt, even with a new
        # browser authorization key. A rejected attempt needs a fresh explicit authorization.
        snapshot
      else
        if snapshot, do: Repo.rollback(:stale_preflight)
        unwrap!(Baselines.authorize(scope, monitor_id, Map.put(attrs, "samples_per_case", 1)))
      end
    end)
  end

  def authorize(_scope, _monitor_id, _attrs), do: {:error, :authorization_required}

  def review(scope, monitor_id, attrs) do
    scoped_transaction(scope, monitor_id, fn state ->
      ensure_review!(state, attrs)
      record_review!(scope, monitor_id, state)
      state.baseline.snapshot
    end)
  end

  def finish(scope, monitor_id, attrs) do
    owner_transaction(scope, monitor_id, fn state ->
      ensure_review!(state, attrs)
      ensure_original!(state)
      if not state.can_finish?, do: Repo.rollback(:result_not_approvable)
      record_review!(scope, monitor_id, state)

      if state.completed? do
        # Never reset a later recurring schedule on a duplicate Finish submission.
        state.baseline.snapshot
      else
        snapshot =
          if state.baseline.snapshot.status == :approved,
            do: state.baseline.snapshot,
            else: unwrap!(Baselines.approve(scope, monitor_id, %{approval_mode: :normal}))

        unwrap!(MonitorOperations.configure(scope, monitor_id, %{cadence: :manual}))
        snapshot
      end
    end)
  end

  def reject(scope, monitor_id, attrs) do
    owner_transaction(scope, monitor_id, fn state ->
      ensure_review!(state, attrs)
      if state.baseline.snapshot.status != :pending, do: Repo.rollback(:stale_review)
      record_review!(scope, monitor_id, state)
      unwrap!(Baselines.reject(scope, monitor_id))
    end)
  end

  defp ensure_review!(state, attrs) do
    if not (is_map(attrs) and attrs["confirmed"] == true and not is_nil(state.baseline.snapshot) and
              state.baseline.health.terminal? and
              attrs["snapshot_id"] == state.baseline.snapshot.id and
              is_binary(attrs["review_fingerprint"]) and
              attrs["review_fingerprint"] == state.review_fingerprint),
       do: Repo.rollback(:stale_review)
  end

  defp ensure_original!(state) do
    if not state.original?, do: Repo.rollback(:advanced_configuration)
  end

  defp record_review!(scope, monitor_id, state) do
    unless reviewed?(scope, monitor_id, state.review_fingerprint) do
      ProductAnalytics.record!(scope, "guided_setup.results_reviewed", monitor_id, %{
        "snapshot_id" => state.baseline.snapshot.id,
        "review_fingerprint" => state.review_fingerprint
      })
    end
  end

  defp reviewed?(_scope, _monitor_id, nil), do: false

  defp reviewed?(scope, monitor_id, fingerprint) do
    Repo.exists?(
      from event in ProductEvent,
        where:
          event.workspace_id == ^scope.workspace.id and event.target_id == ^monitor_id and
            event.name == "guided_setup.results_reviewed" and
            fragment("?->>'review_fingerprint' = ?", event.properties, ^fingerprint)
    )
  end

  defp owner(%Scope{membership: %Membership{role: :owner}}), do: :ok
  defp owner(_), do: {:error, :owner_required}

  defp owner_transaction(scope, monitor_id, callback) do
    with :ok <- owner(scope), do: scoped_transaction(scope, monitor_id, callback)
  end

  defp scoped_transaction(
         %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}} = scope,
         monitor_id,
         callback
       ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        # Match the scheduling/capture lock order. Lock snapshots as well because the
        # advanced approval/rejection path can operate without the monitor lock.
        Repo.one!(
          from workspace in Workspace, where: workspace.id == ^workspace_id, lock: "FOR UPDATE"
        )

        case Repo.one(
               from monitor in Monitor,
                 where: monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id,
                 lock: "FOR UPDATE"
             ) do
          nil -> Repo.rollback(:not_found)
          _ -> :ok
        end

        Repo.all(
          from snapshot in BaselineSnapshot,
            where: snapshot.workspace_id == ^workspace_id and snapshot.monitor_id == ^monitor_id,
            order_by: snapshot.id,
            lock: "FOR UPDATE"
        )

        state = unwrap!(get_state(scope, monitor_id))
        callback.(state)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp scoped_transaction(%Scope{}, _, _), do: {:error, :not_found}
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp review_fingerprint(nil), do: nil

  defp review_fingerprint(snapshot) do
    Fingerprint.digest(%{
      "snapshot" => snapshot.id,
      "run_status" => snapshot.capture_run.status,
      "preview" => snapshot.preview_fingerprint,
      "observations" =>
        snapshot.capture_run.observations
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn observation ->
          %{
            "id" => observation.id,
            "status" => observation.status,
            "output" => observation.output_text,
            "completion" => observation.completion_state,
            "request" => observation.request_fingerprint,
            "evaluations" =>
              observation.evaluations
              |> Enum.sort_by(& &1.id)
              |> Enum.map(
                &Map.take(&1, [
                  :id,
                  :status,
                  :contract_version_id,
                  :evaluator_engine_version,
                  :case_expectation_fingerprint
                ])
              )
          }
        end)
    })
  end
end
