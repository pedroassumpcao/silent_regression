defmodule SilentRegressionWeb.ProviderCredentialController do
  use SilentRegressionWeb, :controller

  import Inertia.Controller, only: [assign_errors: 2]

  alias SilentRegression.ProviderCredentials
  alias SilentRegression.Providers.Failure

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    conn
    |> assign(:page_title, "Provider credentials")
    |> render_inertia("Credentials/Index", %{
      can_manage: scope.membership.role == :owner,
      credentials: Enum.map(ProviderCredentials.list_credentials(scope), &credential_prop/1),
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
        |> put_flash(:info, "Credential rotated. Validate the replacement before using it.")
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
      inserted_at: credential.inserted_at
    }
  end

  defp lifecycle_error(conn, :owner_required), do: send_resp(conn, :forbidden, "Forbidden")
  defp lifecycle_error(conn, :not_found), do: send_resp(conn, :not_found, "Not found")

  defp lifecycle_error(conn, :not_active) do
    conn
    |> put_flash(:error, "This credential is no longer active.")
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
end
