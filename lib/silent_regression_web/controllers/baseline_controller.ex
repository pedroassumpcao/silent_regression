defmodule SilentRegressionWeb.BaselineController do
  use SilentRegressionWeb, :controller

  import Inertia.Controller, only: [assign_errors: 2]

  alias SilentRegression.Baselines

  @terminal_run_statuses [:succeeded, :partial_failed, :failed, :cancelled, :needs_review]

  def show(conn, %{"monitor_id" => monitor_id} = params) do
    samples_per_case = get_in(params, ["baseline", "samples_per_case"])

    case Baselines.get_state(conn.assigns.current_scope, monitor_id, %{
           samples_per_case: samples_per_case
         }) do
      {:ok, state} -> render_baseline(conn, state)
      {:error, :not_found} -> send_resp(conn, :not_found, "Not found")
      {:error, _reason} -> baseline_failed(conn, monitor_id, "Baseline state is unavailable.")
    end
  end

  def validate_model(conn, %{"monitor_id" => monitor_id}) do
    case Baselines.validate_model_access(conn.assigns.current_scope, monitor_id) do
      {:ok, _preflight} ->
        conn
        |> put_flash(:info, "Exact model access verified. No completion call was made.")
        |> redirect(to: baseline_path(conn, monitor_id))

      {:error, :owner_required} ->
        owner_required(conn, monitor_id, "verify model access")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        baseline_failed(conn, monitor_id, "Exact model access could not be verified.")
    end
  end

  def authorize(conn, %{"monitor_id" => monitor_id} = params) do
    case Baselines.authorize(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "baseline", %{})
         ) do
      {:ok, _snapshot} ->
        conn
        |> put_flash(:info, "Baseline capture authorized and queued.")
        |> redirect(to: baseline_path(conn, monitor_id))

      {:error, {:preflight_blocked, blockers}} ->
        approval_blocked(conn, monitor_id, blockers)

      {:error, :stale_preflight} ->
        baseline_failed(
          conn,
          monitor_id,
          "The preview changed before authorization. Review the refreshed limits and try again."
        )

      {:error, :identity_conflict} ->
        baseline_failed(
          conn,
          monitor_id,
          "That authorization was already used for a different preview. Refresh and try again."
        )

      {:error, :capture_in_progress} ->
        baseline_failed(conn, monitor_id, "A baseline capture is already in progress.")

      {:error, :owner_required} ->
        owner_required(conn, monitor_id, "authorize provider spend")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        baseline_failed(conn, monitor_id, "The baseline capture could not be authorized.")
    end
  end

  def approve(conn, %{"monitor_id" => monitor_id} = params) do
    case Baselines.approve(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "baseline", %{})
         ) do
      {:ok, _snapshot} ->
        conn
        |> put_flash(:info, "Baseline approved and sealed with its exact observations.")
        |> redirect(to: baseline_path(conn, monitor_id))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :update})
        |> redirect(to: baseline_path(conn, monitor_id))

      {:error, {:approval_blocked, blockers}} ->
        approval_blocked(conn, monitor_id, blockers)

      {:error, :incompatible_baseline} ->
        baseline_failed(
          conn,
          monitor_id,
          "The monitor or contract changed after capture. Authorize a compatible replacement baseline."
        )

      {:error, :owner_required} ->
        owner_required(conn, monitor_id, "approve a baseline")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        baseline_failed(conn, monitor_id, "The baseline could not be approved.")
    end
  end

  def reject(conn, %{"monitor_id" => monitor_id}) do
    case Baselines.reject(conn.assigns.current_scope, monitor_id) do
      {:ok, _snapshot} ->
        conn
        |> put_flash(:info, "Pending baseline rejected. Any queued work was cancelled.")
        |> redirect(to: baseline_path(conn, monitor_id))

      {:error, :owner_required} ->
        owner_required(conn, monitor_id, "reject a baseline")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        baseline_failed(conn, monitor_id, "The baseline could not be rejected.")
    end
  end

  defp render_baseline(conn, state) do
    health = health_prop(state.health)

    conn
    |> assign(:page_title, "Baseline · #{state.preflight.monitor.name}")
    |> render_inertia("Monitors/Baseline", %{
      authorization_key: Ecto.UUID.generate(),
      can_decide: conn.assigns.current_scope.membership.role == :owner,
      compatibility: %{
        compatible: state.compatibility.compatible?,
        mismatches: state.compatibility.mismatches
      },
      health: health,
      monitor: monitor_prop(state.preflight),
      polling: polling?(state.snapshot),
      preflight: preflight_prop(state.preflight),
      release_stage: "Private alpha",
      snapshot: snapshot_prop(state.snapshot, health)
    })
  end

  defp monitor_prop(preflight) do
    version = preflight.monitor_version

    %{
      id: preflight.monitor.id,
      name: preflight.monitor.name,
      description: preflight.monitor.description,
      state: preflight.monitor.state,
      version: version && version.version
    }
  end

  defp preflight_prop(preflight) do
    version = preflight.monitor_version
    credential = preflight.credential

    %{
      ready: preflight.ready?,
      blockers: preflight.blockers,
      case_count: length(preflight.cases),
      cases:
        Enum.map(preflight.cases, fn case_version ->
          %{id: case_version.id, key: case_version.case_key, name: case_version.name}
        end),
      samples_per_case: preflight.samples_per_case,
      maximum_samples: SilentRegression.Baselines.Preflight.maximum_samples(),
      retry_limit: preflight.retry_limit,
      planned_call_count: preflight.planned_call_count,
      maximum_call_count: preflight.maximum_call_count,
      call_cap: preflight.call_cap,
      remaining_call_capacity: preflight.remaining_call_capacity,
      max_output_tokens_per_call: preflight.max_output_tokens_per_call,
      maximum_output_tokens: preflight.maximum_output_tokens,
      preview_fingerprint: preflight.preview_fingerprint,
      provider: version && version.provider,
      requested_model: version && version.requested_model,
      credential:
        credential &&
          %{
            id: credential.id,
            label: credential.label,
            secret_suffix: credential.secret_suffix,
            status: credential.status,
            model_access_verified:
              (version && credential.last_validation_status == :succeeded) and
                credential.last_requested_model == version.requested_model and
                credential.last_returned_model == version.requested_model
          }
    }
  end

  defp snapshot_prop(nil, _health), do: nil

  defp snapshot_prop(snapshot, health) do
    %{
      id: snapshot.id,
      status: snapshot.status,
      approval_mode: snapshot.approval_mode,
      approval_rationale: snapshot.approval_rationale,
      authorized_at: snapshot.authorized_at,
      approved_at: snapshot.approved_at,
      rejected_at: snapshot.rejected_at,
      provider: snapshot.provider,
      requested_model: snapshot.requested_model,
      samples_per_case: snapshot.samples_per_case,
      retry_limit: snapshot.retry_limit,
      planned_call_count: snapshot.planned_call_count,
      maximum_call_count: snapshot.maximum_call_count,
      preview_fingerprint: snapshot.preview_fingerprint,
      member_count: length(snapshot.members),
      run: %{
        id: snapshot.capture_run.id,
        status: snapshot.capture_run.status,
        started_at: snapshot.capture_run.started_at,
        completed_at: snapshot.capture_run.completed_at,
        actual_call_count: health && health.actual_call_count,
        observations:
          snapshot.capture_run.observations
          |> Enum.sort_by(&{&1.case_version.position, &1.sample_index, &1.id})
          |> Enum.map(&observation_prop(&1, snapshot))
      }
    }
  end

  defp observation_prop(observation, snapshot) do
    evaluation =
      Enum.find(
        observation.evaluations,
        &(&1.contract_version_id == snapshot.contract_version_id and
            &1.evaluator_engine_version == snapshot.evaluator_engine_version)
      )

    %{
      id: observation.id,
      case_key: observation.case_version.case_key,
      case_name: observation.case_version.name,
      sample_index: observation.sample_index,
      status: observation.status,
      completion_state: observation.completion_state,
      requested_model: observation.requested_model,
      returned_model: observation.returned_model,
      output_text: observation.output_text,
      failure_category: observation.failure_category,
      failure_message: observation.failure_message,
      provider_metadata: observation.provider_metadata,
      input_tokens: observation.input_tokens,
      output_tokens: observation.output_tokens,
      latency_ms: observation.latency_ms,
      attempt_count: length(observation.provider_attempts),
      evaluation: evaluation_prop(evaluation)
    }
  end

  defp evaluation_prop(nil), do: nil

  defp evaluation_prop(evaluation) do
    %{
      status: evaluation.status,
      error: evaluation.error,
      rule_results:
        Enum.map(evaluation.rule_results, fn result ->
          %{
            rule_id: result.rule_id,
            rule_type: result.rule_type,
            status: result.status,
            code: result.code,
            explanation: result.explanation,
            evidence: result.evidence
          }
        end)
    }
  end

  defp health_prop(nil), do: nil

  defp health_prop(health) do
    %{
      terminal: health.terminal?,
      run_status: health.run_status,
      planned_call_count: health.planned_call_count,
      maximum_call_count: health.maximum_call_count,
      actual_call_count: health.actual_call_count,
      observation_count: health.observation_count,
      missing_observation_count: health.missing_observation_count,
      status_counts: health.status_counts,
      completion_counts: health.completion_counts,
      evaluation_counts: health.evaluation_counts,
      deterministic_failure_count: health.deterministic_failure_count,
      model_mismatch_count: health.model_mismatch_count,
      input_tokens: health.input_tokens,
      output_tokens: health.output_tokens,
      latency_ms: health.latency_ms,
      operational_blockers: health.operational_blockers,
      normal_approvable: health.normal_approvable?,
      exceptional_approvable: health.exceptional_approvable?
    }
  end

  defp polling?(nil), do: false

  defp polling?(snapshot) do
    snapshot.status == :pending and snapshot.capture_run.status not in @terminal_run_statuses
  end

  defp approval_blocked(conn, monitor_id, blockers) do
    message =
      case blockers do
        [blocker | rest] ->
          suffix = if rest == [], do: "", else: " (+#{length(rest)} more)"
          "#{blocker.message}#{suffix}"

        [] ->
          "Resolve the baseline blockers first."
      end

    baseline_failed(conn, monitor_id, message)
  end

  defp owner_required(conn, monitor_id, action) do
    baseline_failed(conn, monitor_id, "Only a workspace owner can #{action}.")
  end

  defp baseline_failed(conn, monitor_id, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: baseline_path(conn, monitor_id))
  end

  defp baseline_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/baseline"
  end
end
