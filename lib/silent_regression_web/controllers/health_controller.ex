defmodule SilentRegressionWeb.HealthController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.OperationalHealth

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    case OperationalHealth.readiness() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end

  def operations(conn, _params) do
    snapshot = OperationalHealth.snapshot()
    status = if snapshot.status == :critical, do: :service_unavailable, else: :ok

    conn
    |> put_status(status)
    |> json(snapshot)
  end
end
