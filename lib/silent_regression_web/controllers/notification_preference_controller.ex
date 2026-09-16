defmodule SilentRegressionWeb.NotificationPreferenceController do
  use SilentRegressionWeb, :controller

  import Inertia.Controller, only: [assign_errors: 2]

  alias SilentRegression.Notifications

  def edit(conn, _params) do
    preference = Notifications.get_preference(conn.assigns.current_scope)

    conn
    |> assign(:page_title, "Notification settings")
    |> render_inertia("Settings/Notifications", %{
      preference: %{
        actionable_alert_email_enabled: preference.actionable_alert_email_enabled
      },
      release_stage: "Private alpha"
    })
  end

  def update(conn, params) do
    attrs = Map.get(params, "notification_preference", %{})

    case Notifications.update_preference(conn.assigns.current_scope, attrs) do
      {:ok, _preference} ->
        conn
        |> put_flash(:info, "Notification preference saved.")
        |> redirect(to: preference_path(conn))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :update})
        |> redirect(to: preference_path(conn))

      {:error, _reason} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  defp preference_path(conn) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/settings/notifications"
  end
end
