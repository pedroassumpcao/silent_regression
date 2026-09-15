defmodule SilentRegression.Contracts.StrictJson do
  @moduledoc false

  @type reason :: :invalid_json | :duplicate_object_key | :invalid_utf8

  @spec decode(String.t()) :: {:ok, Jason.decode_value()} | {:error, reason()}
  def decode(encoded) when is_binary(encoded) do
    if String.valid?(encoded) do
      case Jason.decode(encoded, objects: :ordered_objects) do
        {:ok, value} -> normalize(value)
        {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      end
    else
      {:error, :invalid_utf8}
    end
  end

  defp normalize(%Jason.OrderedObject{values: entries}) do
    keys = Enum.map(entries, &elem(&1, 0))

    if Enum.uniq(keys) == keys do
      Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
        case normalize(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(normalized, key, value)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :duplicate_object_key}
    end
  end

  defp normalize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case normalize(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp normalize(value), do: {:ok, value}
end
