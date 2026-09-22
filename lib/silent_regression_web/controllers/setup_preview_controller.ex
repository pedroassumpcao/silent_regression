defmodule SilentRegressionWeb.SetupPreviewController do
  use SilentRegressionWeb, :controller

  # Deliberately no authoring/execution context: this GET only renders a local simulation.
  def show(conn, _params) do
    conn
    |> assign(:page_title, "Setup design preview")
    |> render_inertia("Monitors/SetupPreview", %{})
  end
end
