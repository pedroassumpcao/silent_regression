defmodule SilentRegression.RunResults.SafeValue do
  @moduledoc false

  @content_bytes 12_000
  @structured_string_bytes 1_000
  @maximum_depth 8
  @maximum_entries 30

  @sensitive_keys MapSet.new(~w(
    authorization
    api_key
    apikey
    password
    secret
    credential
    encrypted_secret
    request_body
    headers
    system_prompt
    user_prompt
    user_prompt_template
    prompt
    context
    frozen_context
    output
    output_text
  ))

  @provider_metadata_keys MapSet.new(~w(
    api_endpoint
    api_version
    http_method
    client_request_id
    model_mismatch
    attempts
    max_retries
    provider_code
    provider_param
    provider_type
    retries_exhausted
    status
  ))

  def text(value, limit \\ @content_bytes)

  def text(nil, _limit), do: nil

  def text(value, limit) when is_binary(value) and is_integer(limit) do
    original_bytes = byte_size(value)
    preview = utf8_prefix(value, limit)

    %{
      text: preview,
      truncated: byte_size(preview) < original_bytes,
      original_bytes: original_bytes
    }
  end

  def structured(value), do: sanitize(value, 0)

  def provider_metadata(value) when is_map(value) do
    value
    |> Enum.filter(fn {key, _value} ->
      MapSet.member?(@provider_metadata_keys, to_string(key))
    end)
    |> Map.new()
    |> structured()
  end

  def provider_metadata(_value), do: %{}

  def diagnostic(value), do: sanitize(value, 0)

  def sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    MapSet.member?(@sensitive_keys, normalized)
  end

  defp sanitize(_value, depth) when depth >= @maximum_depth do
    %{"truncated" => true, "reason" => "maximum_depth"}
  end

  defp sanitize(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp sanitize(%DateTime{} = value, _depth), do: DateTime.to_iso8601(value)
  defp sanitize(%NaiveDateTime{} = value, _depth), do: NaiveDateTime.to_iso8601(value)
  defp sanitize(%Date{} = value, _depth), do: Date.to_iso8601(value)
  defp sanitize(%Time{} = value, _depth), do: Time.to_iso8601(value)
  defp sanitize(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp sanitize(value, _depth) when is_binary(value) do
    case text(value, @structured_string_bytes) do
      %{truncated: false, text: preview} ->
        preview

      %{truncated: true, text: preview, original_bytes: original_bytes} ->
        %{"preview" => preview, "truncated" => true, "original_bytes" => original_bytes}
    end
  end

  defp sanitize(value, depth) when is_list(value) do
    items = value |> Enum.take(@maximum_entries) |> Enum.map(&sanitize(&1, depth + 1))

    if length(value) > length(items) do
      items ++ [%{"truncated" => true, "remaining_items" => length(value) - length(items)}]
    else
      items
    end
  end

  defp sanitize(value, depth) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, child} -> {to_string(key), child} end)
      |> Enum.sort_by(&elem(&1, 0))

    kept =
      entries
      |> Enum.take(@maximum_entries)
      |> Map.new(fn {key, child} ->
        if sensitive_key?(key) do
          {key, "[REDACTED]"}
        else
          {key, sanitize(child, depth + 1)}
        end
      end)

    if length(entries) > map_size(kept) do
      Map.put(kept, "_truncated_entries", length(entries) - map_size(kept))
    else
      kept
    end
  end

  defp sanitize(value, _depth), do: inspect(value, limit: 20, printable_limit: 200)

  defp utf8_prefix(value, limit) when byte_size(value) <= limit, do: value

  defp utf8_prefix(value, limit) do
    value
    |> binary_part(0, max(limit, 0))
    |> trim_to_valid_utf8()
  end

  defp trim_to_valid_utf8(value) do
    if String.valid?(value) do
      value
    else
      trim_to_valid_utf8(binary_part(value, 0, byte_size(value) - 1))
    end
  end
end
