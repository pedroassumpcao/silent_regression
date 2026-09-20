defmodule SilentRegressionWeb.ProviderCredentialController do
  use SilentRegressionWeb, :controller

  import Inertia.Controller, only: [assign_errors: 2]

  alias SilentRegression.ProviderCredentials
  alias SilentRegression.Providers.Failure
  alias SilentRegressionWeb.RateLimit

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    conn
    |> assign(:page_title, "Provider credentials")
    |> render_inertia("Credentials/Index", %{
      can_manage: scope.membership.role == :owner,
      credentials:
        Enum.map(ProviderCredentials.list_credential_overviews(scope), &credential_prop/1),
      release_stage: "Private alpha"
    })
  end

  def create(conn, params) do
    attrs = Map.get(params, "provider_credential", %{})

    case ProviderCredentials.create_credential(conn.assigns.current_scope, attrs) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Credential stored. Validate it before using it in a monitor.")
        |> redirect(to: credentials_path(conn))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :insert})
        |> redirect(to: credentials_path(conn))

      {:error, reason} ->
        lifecycle_error(conn, reason)
    end
  end

  def validate(conn, %{"id" => credential_id}) do
    case RateLimit.check(conn, :credential_validation, rate_subject(conn, credential_id)) do
      :ok ->
        case ProviderCredentials.validate_credential(conn.assigns.current_scope, credential_id) do
          {:ok, _credential} ->
            conn
            |> put_flash(:info, "Credential validated successfully.")
            |> redirect(to: credentials_path(conn))

          {:error, %Failure{} = failure} ->
            conn
            |> put_flash(:error, failure.message)
            |> redirect(to: credentials_path(conn))

          {:error, reason} ->
            lifecycle_error(conn, reason)
        end

      {:error, state} ->
        RateLimit.reject(conn, state)
    end
  end

  def rotate(conn, %{"id" => credential_id} = params) do
    attrs = Map.get(params, "provider_credential", %{})

    case ProviderCredentials.rotate_credential(
           conn.assigns.current_scope,
           credential_id,
           attrs
         ) do
      {:ok, _credential} ->
        conn
        |> put_flash(
          :info,
          "Replacement stored. The current credential remains attached until you validate and activate its successor."
        )
        |> redirect(to: credentials_path(conn))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :insert})
        |> redirect(to: credentials_path(conn))

      {:error, reason} ->
        lifecycle_error(conn, reason)
    end
  end

  def revoke(conn, %{"id" => credential_id}) do
    case ProviderCredentials.revoke_credential(conn.assigns.current_scope, credential_id) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Credential revoked.")
        |> redirect(to: credentials_path(conn))

      {:error, reason} ->
        lifecycle_error(conn, reason)
    end
  end

  def activate_replacement(conn, %{"id" => credential_id}) do
    case RateLimit.check(conn, :credential_validation, rate_subject(conn, credential_id)) do
      :ok -> activate_replacement_credential(conn, credential_id)
      {:error, state} -> RateLimit.reject(conn, state)
    end
  end

  defp activate_replacement_credential(conn, credential_id) do
    case ProviderCredentials.activate_replacement(conn.assigns.current_scope, credential_id) do
      {:ok, result} ->
        conn
        |> put_flash(:info, replacement_message(result))
        |> redirect(to: credentials_path(conn))

      {:error, %Failure{} = failure} ->
        conn
        |> put_flash(:error, failure.message)
        |> redirect(to: credentials_path(conn))

      {:error, :replacement_work_in_progress} ->
        conn
        |> put_flash(
          :error,
          "Finish or reject the affected in-progress run or baseline capture before activating this replacement."
        )
        |> redirect(to: credentials_path(conn))

      {:error, :affected_model_not_allowed} ->
        conn
        |> put_flash(
          :error,
          "An affected monitor uses a model that is no longer available for new validation."
        )
        |> redirect(to: credentials_path(conn))

      {:error, reason} ->
        lifecycle_error(conn, reason)
    end
  end

  defp credential_prop(credential) do
    %{
      id: credential.id,
      provider: credential.provider,
      label: credential.label,
      secret_suffix: credential.secret_suffix,
      status: credential.status,
      last_validation_status: credential.last_validation_status,
      last_failure_category: credential.last_failure_category,
      last_validated_at: credential.last_validated_at,
      last_requested_model: credential.last_requested_model,
      last_returned_model: credential.last_returned_model,
      last_provider_request_id: credential.last_provider_request_id,
      last_validation_attempts: credential.last_validation_attempts,
      supersedes_id: credential.supersedes_id,
      successor_id: credential.successor_id,
      replacement_pending: credential.replacement_pending,
      verified_models: credential.verified_models,
      attached_monitors: Enum.map(credential.attached_monitors, &monitor_impact_prop/1),
      replacement_impact: Enum.map(credential.replacement_impact, &monitor_impact_prop/1),
      inserted_at: credential.inserted_at
    }
  end

  defp monitor_impact_prop(monitor) do
    %{
      id: monitor.id,
      name: monitor.name,
      state: monitor.state,
      requested_models: monitor.requested_models,
      reference_replacement_required: monitor.reference_replacement_required
    }
  end

  defp replacement_message(result) do
    base =
      "Replacement activated for #{result.affected_monitor_count} #{pluralize(result.affected_monitor_count, "monitor", "monitors")}."

    if result.reference_replacement_count > 0 do
      base <>
        " #{result.reference_replacement_count} #{pluralize(result.reference_replacement_count, "monitor requires", "monitors require")} a replacement baseline before monitoring resumes."
    else
      base
    end
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  defp lifecycle_error(conn, :owner_required), do: send_resp(conn, :forbidden, "Forbidden")
  defp lifecycle_error(conn, :not_found), do: send_resp(conn, :not_found, "Not found")

  defp lifecycle_error(conn, :not_active) do
    conn
    |> put_flash(:error, "This credential is no longer active.")
    |> redirect(to: credentials_path(conn))
  end

  defp lifecycle_error(conn, :replacement_pending) do
    conn
    |> put_flash(:error, "This credential already has a pending replacement.")
    |> redirect(to: credentials_path(conn))
  end

  defp lifecycle_error(conn, reason)
       when reason in [:invalid_replacement, :replacement_validation_stale] do
    conn
    |> put_flash(:error, "Validate this replacement against every affected model and try again.")
    |> redirect(to: credentials_path(conn))
  end

  defp lifecycle_error(conn, :replacement_impact_changed) do
    conn
    |> put_flash(
      :error,
      "The affected monitors changed during validation. Review them and try again."
    )
    |> redirect(to: credentials_path(conn))
  end

  defp lifecycle_error(conn, _reason) do
    conn
    |> put_flash(:error, "The credential action could not be completed.")
    |> redirect(to: credentials_path(conn))
  end

  defp credentials_path(conn) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/credentials"
  end

  defp rate_subject(conn, credential_id) do
    scope = conn.assigns.current_scope
    [scope.workspace.id, scope.user.id, credential_id]
  end
end
