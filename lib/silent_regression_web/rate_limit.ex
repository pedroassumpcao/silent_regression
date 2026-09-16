defmodule SilentRegressionWeb.RateLimit do
  @moduledoc false

  import Plug.Conn

  alias SilentRegression.RateLimits

  def check(conn, action, identifiers) when is_list(identifiers) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    [["ip", ip], ["request", ip | identifiers]]
    |> Enum.reduce_while(:ok, fn subject, :ok ->
      case RateLimits.check(action, subject) do
        {:ok, _state} -> {:cont, :ok}
        {:error, state} -> {:halt, {:error, state}}
      end
    end)
  end

  def reject(conn, %{retry_after: retry_after}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send_resp(:too_many_requests, "Too many attempts. Try again later.")
  end
end
