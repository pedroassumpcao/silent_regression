defmodule SilentRegressionWeb.Plugs.RequireOperationalHealthToken do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:silent_regression, :operational_health_token)

    with expected when is_binary(expected) and byte_size(expected) >= 32 <- expected,
         ["Bearer " <> supplied] <- get_req_header(conn, "authorization"),
         true <- secure_compare(expected, supplied) do
      conn
    else
      _other ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp secure_compare(expected, supplied) do
    byte_size(expected) == byte_size(supplied) and Plug.Crypto.secure_compare(expected, supplied)
  end
end
