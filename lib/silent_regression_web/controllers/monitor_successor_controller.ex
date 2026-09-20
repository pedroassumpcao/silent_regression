defmodule SilentRegressionWeb.MonitorSuccessorController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.MonitorSetups
  alias SilentRegression.ProviderCredentials
  alias SilentRegressionWeb.RateLimit

  def start(conn, %{"monitor_id" => monitor_id} = params) do
    case MonitorSetups.start_successor(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "review_id")
         ) do
      {:ok, _setup} ->
        conn
        |> put_flash(:info, "Successor draft copied from the active configuration.")
        |> redirect(to: setup_path(conn, monitor_id))

      {:error, :owner_required} ->
        failed(conn, monitor_id, "Only a workspace owner can start a successor.")

      {:error, :successor_already_exists} ->
        redirect(conn, to: setup_path(conn, monitor_id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        failed(conn, monitor_id, "A successor draft could not be started.")
    end
  end

  def show(conn, %{"monitor_id" => monitor_id}) do
    case MonitorSetups.successor_state(conn.assigns.current_scope, monitor_id) do
      {:ok, state} -> render_successor(conn, state)
      {:error, :not_found} -> send_resp(conn, :not_found, "Not found")
    end
  end

  def validate_model(conn, %{"monitor_id" => monitor_id}) do
    case RateLimit.check(conn, :credential_validation, rate_subject(conn, monitor_id)) do
      :ok ->
        with {:ok, state} <- MonitorSetups.successor_state(conn.assigns.current_scope, monitor_id),
             true <- state.can_activate?,
             {:ok, _validation} <-
               ProviderCredentials.validate_credential(
                 conn.assigns.current_scope,
                 state.setup.provider_credential_id,
                 %{model: state.setup.requested_model}
               ) do
          conn
          |> put_flash(:info, "Exact-model access verified for this successor.")
          |> redirect(to: successor_path(conn, monitor_id))
        else
          false ->
            failed(conn, monitor_id, "Only a workspace owner can validate this successor.")

          {:error, :owner_required} ->
            failed(conn, monitor_id, "Only a workspace owner can validate this successor.")

          {:error, :not_found} ->
            send_resp(conn, :not_found, "Not found")

          {:error, reason} ->
            failed(conn, monitor_id, validation_error(reason))
        end

      {:error, rate_state} ->
        RateLimit.reject(conn, rate_state)
    end
  end

  def activate(conn, %{"monitor_id" => monitor_id} = params) do
    case MonitorSetups.activate_successor(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "preview_fingerprint", "")
         ) do
      {:ok, _result} ->
        conn
        |> put_flash(
          :info,
          "Successor activated. Capture and review a replacement reference before monitoring resumes."
        )
        |> redirect(to: baseline_path(conn, monitor_id))

      {:error, :owner_required} ->
        failed(conn, monitor_id, "Only a workspace owner can activate this successor.")

      {:error, :model_validation_required} ->
        failed(conn, monitor_id, "Verify exact-model access before activation.")

      {:error, :run_in_progress} ->
        failed(conn, monitor_id, "Wait for the unfinished provider run before activation.")

      {:error, :stale_preview} ->
        failed(conn, monitor_id, "Successor readiness changed. Review the refreshed preview.")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        failed(conn, monitor_id, "The successor could not be activated atomically.")
    end
  end

  defp render_successor(conn, state) do
    setup = state.setup

    conn
    |> assign(:page_title, "Configuration successor · #{state.monitor.name}")
    |> render_inertia("Monitors/Successor", %{
      can_activate: state.can_activate?,
      monitor: %{
        id: state.monitor.id,
        name: state.monitor.name,
        state: state.monitor.state
      },
      motivation: motivation_prop(setup.motivating_review_decision),
      preview: %{
        activation_ready: state.preview.activation_ready?,
        active_run: state.preview.active_run?,
        changes: state.preview.changes,
        contract_ready: state.preview.contract_ready?,
        draft_current: state.preview.draft_current?,
        fingerprint: state.preview.fingerprint,
        model_verified: state.preview.model_verified?,
        replacement_reference_required: state.preview.replacement_reference_required?,
        source_current: state.preview.source_current?
      },
      release_stage: "Private alpha",
      setup: %{
        id: setup.id,
        status: setup.status,
        source_version: state.source.version,
        candidate_version: state.candidate && state.candidate.version,
        provider: setup.provider,
        requested_model: setup.requested_model,
        completed_at: setup.completed_at
      }
    })
  end

  defp motivation_prop(nil), do: nil

  defp motivation_prop(review) do
    %{
      id: review.id,
      classification: review.classification,
      action: review.action,
      rationale: review.rationale,
      reviewer: review.reviewer_user && review.reviewer_user.email,
      reviewed_at: review.reviewed_at
    }
  end

  defp validation_error(%{message: message}) when is_binary(message), do: message
  defp validation_error(_reason), do: "Exact-model access could not be verified."

  defp failed(conn, monitor_id, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: successor_path(conn, monitor_id))
  end

  defp setup_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/setup/review"
  end

  defp successor_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/successor"
  end

  defp baseline_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/baseline"
  end

  defp rate_subject(conn, monitor_id) do
    scope = conn.assigns.current_scope
    [scope.workspace.id, scope.user.id, monitor_id, "successor"]
  end
end
