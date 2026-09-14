defmodule SilentRegressionWeb.PublicMetadata do
  @moduledoc false

  import Plug.Conn, only: [assign: 3]

  @default_description "Silent Regression replays critical LLM workflows and reports deterministic contract failures."

  def assign(conn, metadata) when is_list(metadata) do
    Enum.reduce(metadata, conn, fn {key, value}, conn -> assign(conn, key, value) end)
  end

  def absolute_url(path) when is_binary(path) do
    SilentRegressionWeb.Endpoint.url()
    |> ensure_trailing_slash()
    |> URI.merge(path)
    |> URI.to_string()
  end

  def default_description, do: @default_description

  def robots_for_path(path) when is_binary(path) do
    if private_path?(path), do: "noindex,nofollow", else: "index,follow"
  end

  defp private_path?("/app" <> _rest), do: true
  defp private_path?("/design-partner/apply/thanks"), do: true
  defp private_path?(_path), do: false

  defp ensure_trailing_slash(url) do
    if String.ends_with?(url, "/"), do: url, else: url <> "/"
  end
end
