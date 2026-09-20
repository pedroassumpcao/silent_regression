defmodule SilentRegressionWeb.IncidentController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.RunResults.{Incidents, Presenter}

  def index(conn, params) do
    case Incidents.list_workspace(conn.assigns.current_scope, params) do
      {:ok, state} ->
        conn
        |> assign(:page_title, "Incidents")
        |> render_inertia("Alerts/Index", %{
          incidents:
            Enum.map(state.incidents, fn item ->
              Presenter.incident_summary(item.incident, item.latest_occurrence)
            end),
          counts: state.counts,
          pagination: state.pagination,
          can_resolve: state.can_resolve?,
          release_stage: "Private alpha"
        })

      {:error, _reason} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def show(conn, %{"incident_id" => incident_id} = params) do
    case Incidents.get_detail(conn.assigns.current_scope, incident_id, params) do
      {:ok, state} ->
        conn
        |> assign(:page_title, "Incident · #{state.incident.title}")
        |> render_inertia("Alerts/Show", %{
          can_resolve: state.can_resolve?,
          detail:
            Presenter.incident_detail(
              state.incident,
              state.latest_occurrence,
              state.occurrences,
              state.pagination
            ),
          release_stage: "Private alpha"
        })

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def acknowledge(conn, %{"incident_id" => incident_id}) do
    case Incidents.acknowledge(conn.assigns.current_scope, incident_id) do
      {:ok, incident} ->
        conn
        |> put_flash(:info, "Incident acknowledged. Every occurrence remains unchanged.")
        |> redirect(to: incident_path(conn, incident.id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        failed(conn, "The incident could not be acknowledged.")
    end
  end

  def resolve(conn, %{"incident_id" => incident_id}) do
    case Incidents.resolve(conn.assigns.current_scope, incident_id) do
      {:ok, incident} ->
        conn
        |> put_flash(
          :info,
          "Incident resolved. Its occurrence and review history remain available."
        )
        |> redirect(to: incident_path(conn, incident.id))

      {:error, :owner_required} ->
        failed(conn, "Only a workspace owner can resolve an incident.")

      {:error, :acknowledgement_required} ->
        failed(conn, "Acknowledge the incident before resolving it.")

      {:error, :review_required} ->
        failed(conn, "Review the latest occurrence before resolving this incident.")

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        failed(conn, "The incident could not be resolved.")
    end
  end

  defp failed(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/alerts")
  end

  defp incident_path(conn, incident_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/incidents/#{incident_id}"
  end
end
