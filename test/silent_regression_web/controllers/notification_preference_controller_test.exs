defmodule SilentRegressionWeb.NotificationPreferenceControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Notifications

  setup :register_and_log_in_workspace

  test "renders the authenticated member's workspace preference", %{
    conn: conn,
    workspace: workspace
  } do
    conn = get(conn, ~p"/app/#{workspace.slug}/settings/notifications")

    assert html_response(conn, 200)
    assert inertia_component(conn) == "Settings/Notifications"
    assert inertia_props(conn).pageTitle == "Notification settings"

    assert inertia_props(conn).preference == %{
             actionableAlertEmailEnabled: true
           }
  end

  test "updates only the signed-in member's workspace preference", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    conn =
      patch(conn, ~p"/app/#{workspace.slug}/settings/notifications", %{
        "notification_preference" => %{"actionable_alert_email_enabled" => false}
      })

    assert redirected_to(conn) == ~p"/app/#{workspace.slug}/settings/notifications"
    refute Notifications.get_preference(scope).actionable_alert_email_enabled
  end

  test "requires authentication and workspace membership", %{workspace: workspace} do
    assert build_conn()
           |> get(~p"/app/#{workspace.slug}/settings/notifications")
           |> redirected_to() == ~p"/users/log-in"

    outsider = accepted_workspace_fixture()

    assert build_conn()
           |> log_in_user(outsider.user)
           |> get(~p"/app/#{workspace.slug}/settings/notifications")
           |> response(404) == "Not found"
  end
end
