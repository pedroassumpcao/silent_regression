defmodule SilentRegressionWeb.HealthControllerTest do
  use SilentRegressionWeb.ConnCase, async: false

  alias SilentRegression.OperationalHealth

  test "exposes public liveness and database readiness without operational details", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/health/live") |> json_response(200)
    assert %{"status" => "ok"} = conn |> recycle() |> get("/health/ready") |> json_response(200)
  end

  test "protects the detailed operational snapshot with a bearer token", %{conn: conn} do
    assert %{"error" => "unauthorized"} =
             conn |> get("/health/operations") |> json_response(401)

    assert {:ok, _heartbeat} = OperationalHealth.record_heartbeat(:scheduler_dispatch, :ok)

    authorized =
      conn
      |> recycle()
      |> put_req_header(
        "authorization",
        "Bearer test-operational-health-token-with-at-least-32-bytes"
      )
      |> get("/health/operations")

    assert %{"status" => "ok", "checks" => checks} = json_response(authorized, 200)
    assert length(checks) == 5
  end
end
