defmodule SilentRegressionWeb.AppControllerTest do
  use SilentRegressionWeb.ConnCase

  import Inertia.Testing

  test "GET /app renders the React product foundation", %{conn: conn} do
    conn = get(conn, ~p"/app")

    html = html_response(conn, 200)
    assert inertia_component(conn) == "Dashboard"

    assert %{
             foundationStatus: "Ready for product work",
             pageTitle: "Product foundation",
             releaseStage: "Private alpha"
           } = inertia_props(conn)

    assert ["noindex,nofollow"] =
             html
             |> LazyHTML.from_document()
             |> LazyHTML.query("meta[name='robots']")
             |> LazyHTML.attribute("content")
  end
end
