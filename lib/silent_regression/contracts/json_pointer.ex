defmodule SilentRegression.Contracts.JsonPointer do
  @moduledoc """
  Bounded RFC 6901 JSON Pointer parsing and evaluation.
  """

  alias SilentRegression.Contracts.Limits

  @type fetch_reason :: :missing | :invalid_array_index | :wrong_container_type

  @spec parse(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def parse(pointer) when is_binary(pointer) do
    cond do
      not String.valid?(pointer) ->
        {:error, :invalid_utf8}

      String.length(pointer) > Limits.json_pointer_characters() ->
        {:error, :too_long}

      pointer == "" ->
        {:ok, []}

      not String.starts_with?(pointer, "/") ->
        {:error, :must_start_with_slash}

      true ->
        tokens = pointer |> String.split("/", trim: false) |> tl()

        if length(tokens) > Limits.json_pointer_tokens() do
          {:error, :too_many_tokens}
        else
          decode_tokens(tokens, [])
        end
    end
  end

  def parse(_pointer), do: {:error, :must_be_a_string}

  @spec fetch(Jason.decode_value(), [String.t()]) ::
          {:ok, Jason.decode_value()} | {:error, fetch_reason()}
  def fetch(value, []), do: {:ok, value}

  def fetch(value, [token | rest]) when is_map(value) do
    case Map.fetch(value, token) do
      {:ok, nested} -> fetch(nested, rest)
      :error -> {:error, :missing}
    end
  end

  def fetch(value, [token | rest]) when is_list(value) do
    with {:ok, index} <- array_index(token),
         {:ok, nested} <- Enum.fetch(value, index) do
      fetch(nested, rest)
    else
      :error -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch(_value, [_token | _rest]), do: {:error, :wrong_container_type}

  defp decode_tokens([], decoded), do: {:ok, Enum.reverse(decoded)}

  defp decode_tokens([token | rest], decoded) do
    if valid_escapes?(token) do
      token = token |> String.replace("~1", "/") |> String.replace("~0", "~")
      decode_tokens(rest, [token | decoded])
    else
      {:error, :invalid_escape}
    end
  end

  defp valid_escapes?(<<>>), do: true
  defp valid_escapes?(<<"~0", rest::binary>>), do: valid_escapes?(rest)
  defp valid_escapes?(<<"~1", rest::binary>>), do: valid_escapes?(rest)
  defp valid_escapes?(<<"~", _rest::binary>>), do: false
  defp valid_escapes?(<<_byte, rest::binary>>), do: valid_escapes?(rest)

  defp array_index("0"), do: {:ok, 0}

  defp array_index(<<first, rest::binary>> = token) when first in ?1..?9 do
    if digits?(rest), do: {:ok, String.to_integer(token)}, else: {:error, :invalid_array_index}
  end

  defp array_index(_token), do: {:error, :invalid_array_index}

  defp digits?(<<>>), do: true
  defp digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: digits?(rest)
  defp digits?(_rest), do: false
end
