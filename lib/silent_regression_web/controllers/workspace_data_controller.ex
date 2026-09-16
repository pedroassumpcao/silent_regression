defmodule SilentRegressionWeb.WorkspaceDataController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.WorkspaceLifecycle

  def edit(conn, _params) do
    scope = conn.assigns.current_scope

    conn
    |> assign(:page_title, "Data and retention")
    |> render_inertia("Settings/DataRetention", %{
      can_manage: scope.membership.role == :owner,
      policy: %{
        active_workspace: "Raw evidence is retained while the workspace is active.",
        closed_workspace: "A closed workspace is retained for 30 days before deletion.",
        explicit_deletion:
          "An explicit deletion request is due immediately and completed within 7 days.",
        backups: "Disaster-recovery backups expire within 30 days."
      },
      release_stage: "Private alpha"
    })
  end

  def close(conn, %{"confirmation" => confirmation}) do
    close_workspace(conn, :closure_retention, confirmation)
  end

  def close(conn, _params), do: close_workspace(conn, :closure_retention, "")

  def delete(conn, %{"confirmation" => confirmation}) do
    close_workspace(conn, :explicit_request, confirmation)
  end

  def delete(conn, _params), do: close_workspace(conn, :explicit_request, "")

  defp close_workspace(conn, mode, confirmation) do
    case WorkspaceLifecycle.close_workspace(conn.assigns.current_scope, mode, confirmation) do
      {:ok, %{receipt: receipt}} ->
        message =
          case mode do
            :closure_retention ->
              "Workspace closed. Recovery is available to the operator during the 30-day retention window."

            :explicit_request ->
              "Deletion requested. Provider access is disabled and deletion is due immediately. Receipt #{receipt.request_id}."
          end

        conn
        |> put_flash(:info, message)
        |> redirect(to: ~p"/app")

      {:error, :confirmation_mismatch} ->
        conn
        |> put_flash(:error, "Type the exact workspace slug to confirm this action.")
        |> redirect(to: data_settings_path(conn))

      {:error, :owner_required} ->
        conn
        |> put_status(:forbidden)
        |> put_flash(:error, "Only a workspace owner can perform this action.")
        |> redirect(to: data_settings_path(conn))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The workspace could not be updated. Refresh and try again.")
        |> redirect(to: data_settings_path(conn))
    end
  end

  defp data_settings_path(conn) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/settings/data"
  end
end
