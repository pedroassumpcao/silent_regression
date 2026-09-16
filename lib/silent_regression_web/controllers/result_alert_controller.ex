defmodule SilentRegressionWeb.ResultAlertController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.Presenter

  def index(conn, _params) do
    case RunResults.list_workspace_alerts(conn.assigns.current_scope) do
      {:ok, state} ->
        conn
        |> assign(:page_title, "Alerts")
        |> render_inertia("Alerts/Index", %{
          alerts: Enum.map(state.alerts, &Presenter.alert/1),
          can_resolve: state.can_resolve?,
          release_stage: "Private alpha"
        })

      {:error, _reason} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def acknowledge(conn, %{"alert_id" => alert_id}) do
    case RunResults.acknowledge_alert(conn.assigns.current_scope, alert_id) do
      {:ok, alert} ->
        conn
        |> put_flash(:info, "Alert acknowledged. The immutable evidence is unchanged.")
        |> redirect(to: run_path(conn, alert))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        alert_failed(conn, "The alert could not be acknowledged.")
    end
  end

  def resolve(conn, %{"alert_id" => alert_id}) do
    case RunResults.resolve_alert(conn.assigns.current_scope, alert_id) do
      {:ok, alert} ->
        conn
        |> put_flash(:info, "Alert resolved. Its evidence and audit history remain available.")
        |> redirect(to: run_path(conn, alert))

      {:error, :owner_required} ->
        alert_failed(conn, "Only a workspace owner can resolve an alert.")

      {:error, :acknowledgement_required} ->
        alert_failed(conn, "Acknowledge the alert before resolving it.")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        alert_failed(conn, "The alert could not be resolved.")
    end
  end

  defp alert_failed(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/alerts")
  end

  defp run_path(conn, alert) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{alert.monitor_id}/runs/#{alert.capture_run_id}"
  end
end
