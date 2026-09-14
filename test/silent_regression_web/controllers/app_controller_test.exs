defmodule SilentRegressionWeb.AppControllerTest do
  use SilentRegressionWeb.ConnCase

  import Inertia.Testing

  test "GET /app renders the React product foundation", %{conn: conn} do
    conn = get(conn, ~p"/app")

    assert html_response(conn, 200)
    assert inertia_component(conn) == "Dashboard"

    assert %{
             foundationStatus: "Ready for product work",
             pageTitle: "Product foundation",
             releaseStage: "Private alpha"
           } = inertia_props(conn)
  end
end
