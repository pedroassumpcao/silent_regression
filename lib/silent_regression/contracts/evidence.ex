defmodule SilentRegression.Contracts.Evidence do
  @moduledoc false

  alias SilentRegression.Contracts.Limits

  @spec value(term()) :: map()
  def value(value) do
    preview =
      case Jason.encode(value, maps: :strict) do
        {:ok, encoded} -> encoded
        {:error, _reason} -> "<unavailable>"
      end

    excerpt = excerpt(preview)

    %{
      "json_type" => json_type(value),
      "preview" => excerpt.text,
      "truncated" => excerpt.truncated
    }
  end

  @spec text(String.t()) :: map()
  def text(value) when is_binary(value) do
    excerpt = excerpt(value)
    %{"preview" => excerpt.text, "truncated" => excerpt.truncated}
  end

  @spec json_type(term()) :: String.t()
  def json_type(value) when is_map(value), do: "object"
  def json_type(value) when is_list(value), do: "array"
  def json_type(value) when is_binary(value), do: "string"
  def json_type(value) when is_integer(value), do: "integer"
  def json_type(value) when is_float(value), do: "number"
  def json_type(value) when is_boolean(value), do: "boolean"
  def json_type(nil), do: "null"
  def json_type(_value), do: "unknown"

  defp excerpt(value) do
    limit = Limits.evidence_excerpt_bytes()

    if byte_size(value) <= limit do
      %{text: value, truncated: false}
    else
      suffix = "…"
      prefix_limit = limit - byte_size(suffix)
      prefix = valid_prefix(value, prefix_limit)
      %{text: prefix <> suffix, truncated: true}
    end
  end

  defp valid_prefix(value, size) do
    prefix = binary_part(value, 0, size)

    if String.valid?(prefix), do: prefix, else: valid_prefix(value, size - 1)
  end
end
