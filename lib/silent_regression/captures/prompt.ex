defmodule SilentRegression.Captures.Prompt do
  @moduledoc false

  alias SilentRegression.Monitors.Limits

  @placeholder ~r/\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}/

  def render(template, variables) when is_binary(template) and is_map(variables) do
    keys = @placeholder |> Regex.scan(template, capture: :all_but_first) |> List.flatten()

    with {:ok, replacements} <- replacements(keys, variables),
         rendered <-
           Regex.replace(@placeholder, template, fn _match, key ->
             Map.fetch!(replacements, key)
           end),
         true <- String.valid?(rendered),
         true <- byte_size(rendered) <= maximum_rendered_bytes() do
      {:ok, rendered}
    else
      {:error, _reason} = error -> error
      false -> {:error, :rendered_prompt_too_large}
    end
  end

  def render(_template, _variables), do: {:error, :invalid_prompt_template}

  defp replacements(keys, variables) do
    keys
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, replacements} ->
      case Map.fetch(variables, key) do
        {:ok, value} ->
          case encode_value(value) do
            {:ok, encoded} -> {:cont, {:ok, Map.put(replacements, key, encoded)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:halt, {:error, {:missing_prompt_variable, key}}}
      end
    end)
  end

  defp encode_value(value) when is_binary(value), do: {:ok, value}

  defp encode_value(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_prompt_variable}
    end
  end

  defp maximum_rendered_bytes do
    Limits.fetch!(:max_prompt_bytes) + Limits.fetch!(:max_variables_bytes)
  end
end
