defmodule SilentRegression.Baselines do
  @moduledoc """
  Workspace-scoped baseline preflight, authorization, inspection, and immutable approval.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit

  alias SilentRegression.Baselines.{
    BaselineMember,
    BaselineSnapshot,
    Health,
    Preflight
  }

  alias SilentRegression.Captures
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Monitors
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.ProviderCredentials
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  def preflight(scope, monitor_id, attrs \\ %{})

  def preflight(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, samples_per_case} <- Preflight.cast_samples(value(attrs, :samples_per_case)),
         {:ok, resources} <- load_resources(workspace_id, monitor_id) do
      {:ok, Preflight.build(resources, samples_per_case, capture_limit(:max_calls_per_run))}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def preflight(%Scope{}, _monitor_id, _attrs), do: {:error, :workspace_required}

  def get_state(scope, monitor_id, attrs \\ %{})

  def get_state(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}} = scope,
        monitor_id,
        attrs
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, preflight} <- preflight(scope, monitor_id, attrs),
         {:ok, resources} <- load_resources(workspace_id, monitor_id) do
      snapshot = latest_snapshot(workspace_id, monitor_id)

      {:ok,
       %{
         preflight: preflight,
         snapshot: snapshot,
         health: if(snapshot, do: Health.summarize(snapshot), else: nil),
         compatibility: compatibility(snapshot, resources)
       }}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_state(%Scope{}, _monitor_id, _attrs), do: {:error, :workspace_required}

  def validate_model_access(
        %Scope{membership: %Membership{role: :owner}} = scope,
        monitor_id
      ) do
    with {:ok, preflight} <- preflight(scope, monitor_id),
         %MonitorVersion{} = version <- preflight.monitor_version,
         %ProviderCredential{} = credential <- preflight.credential,
         true <- credential.provider == version.provider do
      case ProviderCredentials.validate_credential(scope, credential.id, %{
             model: version.requested_model
           }) do
        {:ok, _metadata} -> preflight(scope, monitor_id)
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :capture_not_ready}
      false -> {:error, :capture_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_model_access(%Scope{}, _monitor_id), do: {:error, :owner_required}

  def authorize(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, authorization_key} <- Ecto.UUID.cast(value(attrs, :authorization_key)),
         {:ok, samples_per_case} <- Preflight.cast_samples(value(attrs, :samples_per_case)),
         {:ok, preflight} <- preflight(scope, monitor_id, %{samples_per_case: samples_per_case}),
         :ok <- ensure_ready(preflight),
         :ok <- ensure_preview_fingerprint(preflight, value(attrs, :preview_fingerprint)) do
      case snapshot_by_authorization(workspace_id, authorization_key) do
        %BaselineSnapshot{monitor_id: ^monitor_id} = snapshot ->
          with :ok <- ensure_same_authorization(snapshot, preflight) do
            enqueue_authorized_snapshot(scope, snapshot)
          end

        %BaselineSnapshot{} ->
          {:error, :not_found}

        nil ->
          create_authorization(scope, monitor_id, authorization_key, preflight, user)
      end
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize(%Scope{}, _monitor_id, _attrs), do: {:error, :owner_required}

  def approve(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, mode} <- approval_mode(value(attrs, :approval_mode)) do
      Repo.transaction(fn ->
        with %BaselineSnapshot{} = snapshot <- locked_pending_snapshot(workspace_id, monitor_id),
             snapshot <- preload_snapshot(snapshot),
             :ok <- ensure_snapshot_compatible(snapshot),
             summary <- Health.summarize(snapshot),
             [] <- Health.approval_blockers(summary, mode),
             {:ok, approved} <- approve_snapshot(snapshot, user, mode, attrs),
             :ok <- insert_members(approved),
             :ok <- record_approval!(approved, user, summary) do
          preload_snapshot(approved)
        else
          nil -> Repo.rollback(:not_found)
          [_blocker | _rest] = blockers -> Repo.rollback({:approval_blocked, blockers})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def approve(%Scope{}, _monitor_id, _attrs), do: {:error, :owner_required}

  def reject(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %BaselineSnapshot{} = snapshot <- pending_snapshot(workspace_id, monitor_id),
         {:ok, _run} <- Captures.cancel_run(scope, snapshot.capture_run_id) do
      Repo.transaction(fn ->
        with %BaselineSnapshot{} = snapshot <- locked_pending_snapshot(workspace_id, monitor_id),
             {:ok, rejected} <-
               snapshot
               |> BaselineSnapshot.reject_changeset(user, DateTime.utc_now())
               |> Repo.update() do
          Audit.record_event!(%{
            action: "baseline.rejected",
            target_type: "baseline_snapshot",
            target_id: rejected.id,
            workspace_id: rejected.workspace_id,
            actor_user_id: user.id,
            metadata: %{"capture_run_id" => rejected.capture_run_id}
          })

          preload_snapshot(rejected)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def reject(%Scope{}, _monitor_id), do: {:error, :owner_required}

  def current_approved(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %BaselineSnapshot{} = snapshot <- approved_snapshot(workspace_id, monitor_id) do
      {:ok, preload_snapshot(snapshot)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def current_approved(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def current_compatible(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %BaselineSnapshot{} = snapshot <- approved_snapshot(workspace_id, monitor_id),
         snapshot <- preload_snapshot(snapshot),
         :ok <- ensure_snapshot_compatible(snapshot) do
      {:ok, snapshot}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :baseline_required}
      {:error, reason} -> {:error, reason}
    end
  end

  def current_compatible(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  @doc false
  def capture_run_compatible?(%CaptureRun{} = run) do
    case approved_snapshot(run.workspace_id, run.monitor_id) do
      %BaselineSnapshot{} = snapshot ->
        snapshot.monitor_version_id == run.monitor_version_id and
          snapshot.contract_version_id == run.contract_version_id and
          snapshot.provider_credential_id == run.provider_credential_id and
          snapshot.provider == run.provider and
          snapshot.requested_model == run.requested_model and
          snapshot.monitor_fingerprint == run.monitor_fingerprint and
          snapshot.case_set_fingerprint == run.case_set_fingerprint and
          snapshot.contract_fingerprint == run.contract_fingerprint and
          snapshot.evaluator_engine_version == run.evaluator_engine_version and
          ensure_snapshot_compatible(snapshot) == :ok

      nil ->
        false
    end
  end

  @doc false
  def authorized_baseline_run?(run_id) do
    BaselineSnapshot
    |> where([snapshot], snapshot.capture_run_id == ^run_id and snapshot.status == :pending)
    |> Repo.exists?()
  end

  defp create_authorization(scope, monitor_id, authorization_key, preflight, user) do
    result =
      Repo.transaction(fn ->
        with nil <- locked_pending_snapshot(scope.workspace.id, monitor_id),
             {:ok, _monitor} <-
               Monitors.prepare_baseline(scope, monitor_id, preflight.monitor_version.id),
             {:ok, refreshed} <-
               preflight(scope, monitor_id, %{samples_per_case: preflight.samples_per_case}),
             :ok <- ensure_ready(refreshed),
             :ok <- ensure_preview_fingerprint(refreshed, preflight.preview_fingerprint),
             {:ok, run} <-
               Captures.plan_run(scope, monitor_id, %{
                 identity_key: "baseline:#{authorization_key}",
                 kind: :baseline,
                 samples_per_case: refreshed.samples_per_case,
                 retry_limit: refreshed.retry_limit,
                 maximum_call_count: refreshed.maximum_call_count
               }),
             {:ok, snapshot} <- insert_snapshot(refreshed, run, authorization_key, user),
             :ok <- record_authorization!(snapshot, user) do
          snapshot
        else
          %BaselineSnapshot{} -> Repo.rollback(:capture_in_progress)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case unwrap_transaction(result) do
      {:ok, snapshot} -> enqueue_authorized_snapshot(scope, snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_snapshot(preflight, run, authorization_key, user) do
    associations = %{
      workspace_id: preflight.monitor.workspace_id,
      monitor_id: preflight.monitor.id,
      monitor_version_id: preflight.monitor_version.id,
      contract_version_id: preflight.contract_version.id,
      provider_credential_id: preflight.credential.id,
      capture_run_id: run.id,
      authorized_by_user_id: user.id
    }

    attrs = %{
      authorization_key: authorization_key,
      preview_fingerprint: preflight.preview_fingerprint,
      provider: preflight.monitor_version.provider,
      requested_model: preflight.monitor_version.requested_model,
      monitor_fingerprint: preflight.monitor_version.fingerprint,
      case_set_fingerprint: preflight.monitor_version.case_set_fingerprint,
      contract_fingerprint: preflight.contract_version.fingerprint,
      evaluator_engine_version: preflight.contract_version.evaluator_engine_version,
      samples_per_case: preflight.samples_per_case,
      retry_limit: preflight.retry_limit,
      planned_call_count: preflight.planned_call_count,
      maximum_call_count: preflight.maximum_call_count,
      authorized_at: DateTime.utc_now()
    }

    %BaselineSnapshot{}
    |> BaselineSnapshot.create_changeset(associations, attrs)
    |> Repo.insert()
  end

  defp enqueue_authorized_snapshot(scope, snapshot) do
    case Captures.enqueue_run(scope, snapshot.capture_run_id) do
      {:ok, _run} -> {:ok, preload_snapshot(Repo.get!(BaselineSnapshot, snapshot.id))}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp approve_snapshot(snapshot, user, mode, attrs) do
    now = DateTime.utc_now()

    with :ok <- supersede_current_approved(snapshot, now),
         {:ok, approved} <-
           snapshot
           |> BaselineSnapshot.approve_changeset(
             user,
             mode,
             value(attrs, :approval_rationale),
             now
           )
           |> Repo.update() do
      {:ok, approved}
    end
  end

  defp supersede_current_approved(snapshot, now) do
    case locked_approved_snapshot(snapshot.workspace_id, snapshot.monitor_id) do
      nil ->
        :ok

      approved ->
        case approved
             |> BaselineSnapshot.supersede_changeset(snapshot, now)
             |> Repo.update() do
          {:ok, _superseded} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp insert_members(snapshot) do
    snapshot.capture_run.observations
    |> Enum.sort_by(&{&1.case_version.position, &1.sample_index, &1.id})
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {observation, position}, :ok ->
      result =
        %BaselineMember{}
        |> BaselineMember.create_changeset(
          snapshot,
          observation,
          observation.case_version,
          %{
            position: position,
            case_key: observation.case_version.case_key,
            sample_index: observation.sample_index,
            case_fingerprint: observation.case_fingerprint,
            request_fingerprint: observation.request_fingerprint
          }
        )
        |> Repo.insert()

      case result do
        {:ok, _member} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp record_authorization!(snapshot, user) do
    Audit.record_event!(%{
      action: "baseline.authorized",
      target_type: "baseline_snapshot",
      target_id: snapshot.id,
      workspace_id: snapshot.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "capture_run_id" => snapshot.capture_run_id,
        "planned_call_count" => snapshot.planned_call_count,
        "maximum_call_count" => snapshot.maximum_call_count,
        "samples_per_case" => snapshot.samples_per_case
      }
    })

    :ok
  end

  defp record_approval!(snapshot, user, summary) do
    Audit.record_event!(%{
      action: "baseline.approved",
      target_type: "baseline_snapshot",
      target_id: snapshot.id,
      workspace_id: snapshot.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "approval_mode" => Atom.to_string(snapshot.approval_mode),
        "capture_run_id" => snapshot.capture_run_id,
        "deterministic_failure_count" => summary.deterministic_failure_count,
        "member_count" => summary.observation_count
      }
    })

    :ok
  end

  defp ensure_ready(%Preflight{ready?: true}), do: :ok
  defp ensure_ready(%Preflight{blockers: blockers}), do: {:error, {:preflight_blocked, blockers}}

  defp ensure_preview_fingerprint(%Preflight{preview_fingerprint: fingerprint}, fingerprint)
       when is_binary(fingerprint),
       do: :ok

  defp ensure_preview_fingerprint(%Preflight{}, _fingerprint), do: {:error, :stale_preflight}

  defp ensure_same_authorization(snapshot, preflight) do
    if snapshot.preview_fingerprint == preflight.preview_fingerprint and
         snapshot.samples_per_case == preflight.samples_per_case do
      :ok
    else
      {:error, :identity_conflict}
    end
  end

  defp ensure_snapshot_compatible(snapshot) do
    current_version = Repo.get(MonitorVersion, snapshot.monitor_version_id)
    current_contract = Repo.get(ContractVersion, snapshot.contract_version_id)
    monitor = Repo.get(Monitor, snapshot.monitor_id)

    compatible? =
      match?(%Monitor{}, monitor) and
        monitor.active_version_id == snapshot.monitor_version_id and
        match?(%MonitorVersion{status: :active}, current_version) and
        match?(%ContractVersion{status: :approved}, current_contract) and
        current_version.fingerprint == snapshot.monitor_fingerprint and
        current_version.case_set_fingerprint == snapshot.case_set_fingerprint and
        current_contract.fingerprint == snapshot.contract_fingerprint and
        current_contract.evaluator_engine_version == snapshot.evaluator_engine_version and
        draft_compatible?(monitor, snapshot)

    if compatible?, do: :ok, else: {:error, :incompatible_baseline}
  end

  defp draft_compatible?(%Monitor{draft_version_id: nil}, _snapshot), do: true

  defp draft_compatible?(%Monitor{draft_version_id: draft_version_id}, snapshot) do
    case Repo.get(MonitorVersion, draft_version_id) do
      %MonitorVersion{} = draft ->
        draft.fingerprint == snapshot.monitor_fingerprint and
          draft.case_set_fingerprint == snapshot.case_set_fingerprint and
          draft.provider == snapshot.provider and
          draft.requested_model == snapshot.requested_model

      nil ->
        false
    end
  end

  defp compatibility(nil, _resources),
    do: %{compatible?: false, mismatches: [:baseline_missing]}

  defp compatibility(snapshot, resources) do
    comparisons = [
      {:monitor_version_fingerprint, snapshot.monitor_fingerprint,
       field(resources.monitor_version, :fingerprint)},
      {:case_set_fingerprint, snapshot.case_set_fingerprint,
       field(resources.monitor_version, :case_set_fingerprint)},
      {:contract_fingerprint, snapshot.contract_fingerprint,
       field(resources.contract_version, :fingerprint)},
      {:evaluator_engine_version, snapshot.evaluator_engine_version,
       field(resources.contract_version, :evaluator_engine_version)},
      {:provider, snapshot.provider, field(resources.monitor_version, :provider)},
      {:requested_model, snapshot.requested_model,
       field(resources.monitor_version, :requested_model)}
    ]

    mismatches =
      comparisons
      |> Enum.reject(fn {_field, expected, actual} -> expected == actual end)
      |> Enum.map(fn {field, _expected, _actual} -> field end)

    %{compatible?: mismatches == [], mismatches: mismatches}
  end

  defp load_resources(workspace_id, monitor_id) do
    case load_monitor(workspace_id, monitor_id) do
      nil ->
        {:error, :not_found}

      monitor ->
        version = load_current_version(monitor)

        {:ok,
         %{
           monitor: monitor,
           monitor_version: version,
           contract_version: load_approved_contract(monitor.id, version_id(version)),
           credential: load_credential(workspace_id, monitor.provider_credential_id)
         }}
    end
  end

  defp load_monitor(workspace_id, monitor_id) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id)
    |> Repo.one()
  end

  defp load_current_version(monitor) do
    version_id = monitor.draft_version_id || monitor.active_version_id

    if version_id do
      MonitorVersion
      |> where([version], version.id == ^version_id and version.monitor_id == ^monitor.id)
      |> preload(:cases)
      |> Repo.one()
    end
  end

  defp load_approved_contract(_monitor_id, nil), do: nil

  defp load_approved_contract(monitor_id, version_id) do
    ContractVersion
    |> where(
      [contract],
      contract.monitor_id == ^monitor_id and contract.monitor_version_id == ^version_id and
        contract.status == :approved
    )
    |> Repo.one()
  end

  defp load_credential(_workspace_id, nil), do: nil

  defp load_credential(workspace_id, credential_id) do
    ProviderCredential
    |> where(
      [credential],
      credential.workspace_id == ^workspace_id and credential.id == ^credential_id
    )
    |> Repo.one()
  end

  defp latest_snapshot(workspace_id, monitor_id) do
    case pending_snapshot(workspace_id, monitor_id) || approved_snapshot(workspace_id, monitor_id) do
      nil -> nil
      snapshot -> preload_snapshot(snapshot)
    end
  end

  defp snapshot_by_authorization(workspace_id, authorization_key) do
    BaselineSnapshot
    |> where(
      [snapshot],
      snapshot.workspace_id == ^workspace_id and
        snapshot.authorization_key == ^authorization_key
    )
    |> Repo.one()
  end

  defp pending_snapshot(workspace_id, monitor_id) do
    BaselineSnapshot
    |> where(
      [snapshot],
      snapshot.workspace_id == ^workspace_id and snapshot.monitor_id == ^monitor_id and
        snapshot.status == :pending
    )
    |> Repo.one()
  end

  defp approved_snapshot(workspace_id, monitor_id) do
    BaselineSnapshot
    |> where(
      [snapshot],
      snapshot.workspace_id == ^workspace_id and snapshot.monitor_id == ^monitor_id and
        snapshot.status == :approved
    )
    |> Repo.one()
  end

  defp locked_pending_snapshot(workspace_id, monitor_id) do
    BaselineSnapshot
    |> where(
      [snapshot],
      snapshot.workspace_id == ^workspace_id and snapshot.monitor_id == ^monitor_id and
        snapshot.status == :pending
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_approved_snapshot(workspace_id, monitor_id) do
    BaselineSnapshot
    |> where(
      [snapshot],
      snapshot.workspace_id == ^workspace_id and snapshot.monitor_id == ^monitor_id and
        snapshot.status == :approved
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp preload_snapshot(snapshot) do
    Repo.preload(
      snapshot,
      [
        :members,
        capture_run: [
          observations: [
            :case_version,
            :provider_attempts,
            evaluations: :rule_results
          ]
        ]
      ],
      force: true
    )
  end

  defp approval_mode(value) when value in [:normal, "normal"], do: {:ok, :normal}
  defp approval_mode(value) when value in [:exceptional, "exceptional"], do: {:ok, :exceptional}
  defp approval_mode(_value), do: {:error, :invalid_approval_mode}

  defp version_id(nil), do: nil
  defp version_id(version), do: version.id

  defp field(nil, _field), do: nil
  defp field(struct, field), do: Map.fetch!(struct, field)

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
