defmodule SilentRegression.Contracts.StrictJson do
  @moduledoc false

  alias SilentRegression.Contracts.Limits

  @type reason :: :invalid_json | :duplicate_object_key | :invalid_utf8 | :nesting_too_deep

  @spec decode(String.t()) :: {:ok, Jason.decode_value()} | {:error, reason()}
  def decode(encoded) when is_binary(encoded) do
    cond do
      not String.valid?(encoded) ->
        {:error, :invalid_utf8}

      nesting_too_deep?(encoded) ->
        {:error, :nesting_too_deep}

      true ->
        case Jason.decode(encoded, objects: :ordered_objects) do
          {:ok, value} -> normalize(value)
          {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
        end
    end
  end

  defp nesting_too_deep?(encoded) do
    case scan_depth(encoded, 0, false, false) do
      :too_deep -> true
      _depth -> false
    end
  end

  defp scan_depth(<<>>, depth, _in_string, _escaped), do: depth

  defp scan_depth(<<_byte, rest::binary>>, depth, true, true),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<"\\", rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, true, true)

  defp scan_depth(<<"\"", rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, false, false)

  defp scan_depth(<<_byte, rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<"\"", rest::binary>>, depth, false, false),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<byte, rest::binary>>, depth, false, false) when byte in [?{, ?[] do
    depth = depth + 1

    if depth > Limits.json_nesting_depth(),
      do: :too_deep,
      else: scan_depth(rest, depth, false, false)
  end

  defp scan_depth(<<byte, rest::binary>>, depth, false, false) when byte in [?}, ?]] do
    scan_depth(rest, depth - 1, false, false)
  end

  defp scan_depth(<<_byte, rest::binary>>, depth, false, false),
    do: scan_depth(rest, depth, false, false)

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
