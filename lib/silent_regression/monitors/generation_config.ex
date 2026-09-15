defmodule SilentRegression.Monitors.GenerationConfig do
  @moduledoc false

  alias SilentRegression.Monitors.{JsonValue, Limits}

  @keys ~w(max_output_tokens temperature top_p reasoning_effort)
  @reasoning_efforts ~w(none minimal low medium high xhigh max)

  def normalize(nil), do: normalize(%{})

  def normalize(config) when is_map(config) do
    with {:ok, config} <- JsonValue.normalize(config),
         [] <- Map.keys(config) -- @keys,
         {:ok, max_output_tokens} <- max_output_tokens(config),
         {:ok, temperature} <- bounded_number(config, "temperature", 0.0, 2.0),
         {:ok, top_p} <- bounded_number(config, "top_p", 0.0, 1.0),
         {:ok, reasoning_effort} <- reasoning_effort(config) do
      normalized =
        %{"max_output_tokens" => max_output_tokens}
        |> put_optional("temperature", temperature)
        |> put_optional("top_p", top_p)
        |> put_optional("reasoning_effort", reasoning_effort)

      with {:ok, size} <- JsonValue.encoded_size(normalized),
           true <- size <= Limits.fetch!(:max_generation_config_bytes) do
        {:ok, normalized}
      else
        _reason -> {:error, :generation_config_too_large}
      end
    else
      _reason -> {:error, :invalid_generation_config}
    end
  end

  def normalize(_config), do: {:error, :invalid_generation_config}

  defp max_output_tokens(config) do
    value = Map.get(config, "max_output_tokens", 512)

    if is_integer(value) and value > 0 and value <= Limits.fetch!(:max_output_tokens) do
      {:ok, value}
    else
      {:error, :invalid_max_output_tokens}
    end
  end

  defp bounded_number(config, key, minimum, maximum) do
    case Map.get(config, key) do
      nil ->
        {:ok, nil}

      value when is_integer(value) or is_float(value) ->
        value = value / 1

        if value >= minimum and value <= maximum,
          do: {:ok, value},
          else: {:error, :out_of_range}

      _value ->
        {:error, :not_a_number}
    end
  end

  defp reasoning_effort(config) do
    case Map.get(config, "reasoning_effort") do
      nil -> {:ok, nil}
      value when value in @reasoning_efforts -> {:ok, value}
      _value -> {:error, :invalid_reasoning_effort}
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
