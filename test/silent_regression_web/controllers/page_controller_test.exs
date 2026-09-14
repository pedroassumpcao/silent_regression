defmodule SilentRegressionWeb.PageControllerTest do
  use SilentRegressionWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Catch silent failures in critical LLM workflows"
  end
end
