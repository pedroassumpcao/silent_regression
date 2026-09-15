defmodule SilentRegression.Monitors.ResponseFormat do
  @moduledoc false

  alias SilentRegression.Monitors.{JsonValue, Limits}

  def normalize(nil), do: normalize(%{"type" => "text"})

  def normalize(value) when is_map(value) do
    with {:ok, normalized} <- JsonValue.normalize(value),
         {:ok, normalized} <- normalize_type(normalized),
         {:ok, size} <- JsonValue.encoded_size(normalized),
         true <- size <= Limits.fetch!(:max_response_format_bytes) do
      {:ok, normalized}
    else
      _reason -> {:error, :invalid_response_format}
    end
  end

  def normalize(_value), do: {:error, :invalid_response_format}

  defp normalize_type(%{"type" => type} = format) when type in ["text", "json_object"] do
    if Map.keys(format) == ["type"], do: {:ok, format}, else: {:error, :unknown_field}
  end

  defp normalize_type(
         %{
           "type" => "json_schema",
           "name" => name,
           "schema" => schema
         } = format
       )
       when is_binary(name) and is_map(schema) do
    if Map.keys(format) -- ~w(name schema strict type) == [] and
         String.trim(name) != "" and byte_size(name) <= 80 and
         Map.get(format, "strict", true) in [true, false] do
      {:ok, Map.put_new(format, "strict", true)}
    else
      {:error, :invalid_json_schema}
    end
  end

  defp normalize_type(_format), do: {:error, :invalid_response_format}
end
