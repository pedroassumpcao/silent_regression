defmodule SilentRegression.Monitors.JsonValue do
  @moduledoc false

  def normalize(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_json_value}
  end

  def normalize(value) when is_integer(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  def normalize(value) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_json_value}
    end
  end

  def normalize(value) when is_list(value) do
    reduce_values(value, [])
  end

  def normalize(%{__struct__: _module}), do: {:error, :invalid_json_value}

  def normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, nested} <- normalize(nested) do
        {:cont, {:ok, Map.put(normalized, key, nested)}}
      else
        _reason -> {:halt, {:error, :invalid_json_value}}
      end
    end)
  end

  def normalize(_value), do: {:error, :invalid_json_value}

  def encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, _reason} -> {:error, :invalid_json_value}
    end
  end

  defp reduce_values([], normalized), do: {:ok, Enum.reverse(normalized)}

  defp reduce_values([value | rest], normalized) do
    case normalize(value) do
      {:ok, value} -> reduce_values(rest, [value | normalized])
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, :invalid_json_value}
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_json_value}
end
