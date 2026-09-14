defmodule SilentRegressionWeb.AppController do
  use SilentRegressionWeb, :controller

  def index(conn, _params) do
    conn
    |> assign(:page_title, "Product foundation")
    |> render_inertia("Dashboard", %{
      release_stage: "Private alpha",
      foundation_status: "Ready for product work"
    })
  end
end
