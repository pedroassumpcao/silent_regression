defmodule SilentRegression.GuidedSetups.JsonRecipe do
  @moduledoc "Required top-level scalar fields and independently declared per-case values. Not JSON Schema."
  alias SilentRegression.GuidedSetups.Recipes

  def empty, do: %{"fields" => []}

  def raw_settings?(%{"fields" => fields} = settings)
      when map_size(settings) == 1 and is_list(fields) do
    length(fields) <= 4 and Enum.all?(fields, &Recipes.strings?(&1, ~w(key type)))
  end

  def raw_settings?(_), do: false

  def prepare(raw) do
    fields = raw["settings"]["fields"]

    with true <- valid_fields?(fields),
         true <- raw["cases"] != [],
         {:ok, prepared} <- prepare_cases(raw["cases"], fields) do
      rules =
        [%{"id" => "valid_json", "type" => "json_valid"}] ++
          Enum.with_index(fields, fn field, i ->
            %{
              "id" => "field_#{i + 1}",
              "type" => "json_path_type",
              "path" => path(field["key"]),
              "expected_type" => field["type"]
            }
          end)

      cases = Enum.map(prepared, & &1.input)
      candidates = Enum.flat_map(prepared, & &1.candidates)
      good = hd(prepared).good

      negatives =
        Enum.flat_map(fields, fn field ->
          key = field["key"]

          [
            {0, Jason.encode!(Map.delete(good, key)), "Missing required field #{key}."},
            {0, Jason.encode!(Map.put(good, key, [])), "Wrong type for #{key}."}
          ]
        end)

      {:ok, rules, cases, candidates ++ negatives ++ [{0, "Not JSON", "Invalid raw JSON."}]}
    else
      {:error, message} ->
        Recipes.error(message)

      _ ->
        Recipes.error(
          "JSON needs 1–4 distinct top-level fields (string, number, integer or boolean), 1–20 examples, and an explicit value for every field in every example. Numeric tolerance must be non-negative. Values/tolerances are bounded to ±1,000,000; strings to 120 bytes. Nested schemas, arrays/objects/null, optional fields, enums, regex, formats and extra-key rejection are not supported by this editor."
        )
    end
  end

  defp valid_fields?(fields) do
    fields != [] and Enum.uniq_by(fields, & &1["key"]) == fields and
      Enum.all?(
        fields,
        &(Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]{0,39}\z/, &1["key"]) and
            &1["type"] in ~w(string number integer boolean))
      )
  end

  defp prepare_cases(rows, fields) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      with {:ok, values} when is_map(values) <- Jason.decode(row["expected"]),
           true <- Enum.sort(Map.keys(values)) == Enum.sort(Enum.map(fields, & &1["key"])),
           {:ok, parsed} <- parse_values(fields, values) do
        checks = Enum.map(parsed, & &1.check)
        good = Map.new(parsed, &{&1.key, &1.value})
        first = hd(parsed)
        wrong = Map.put(good, first.key, wrong_value(first.value, first.tolerance))

        item = %{
          input: Recipes.input(row, index, checks),
          good: good,
          candidates: [
            {index, Jason.encode!(good), "Declared expected values."},
            {index, Jason.encode!(wrong), "Valid field types, but a wrong value for this input."}
          ]
        }

        {:cont, {:ok, acc ++ [item]}}
      else
        {:error, message} when is_binary(message) ->
          {:halt, {:error, "Example #{index + 1}: " <> message}}

        _ ->
          {:halt,
           {:error,
            "Example #{index + 1}: enter an explicit value for every declared field. Remove obsolete fields from any manually edited saved values."}}
      end
    end)
  end

  defp parse_values(fields, values) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {field, index}, {:ok, acc} ->
      value = values[field["key"]]

      with true <- Recipes.strings?(value, ~w(value tolerance)),
           {:ok, parsed} <- scalar(field["type"], value["value"]),
           {:ok, tolerance} <- tolerance(field["type"], value["tolerance"]) do
        check =
          if field["type"] in ~w(number integer),
            do: %{
              "id" => "expected_#{index + 1}",
              "type" => "json_number",
              "path" => path(field["key"]),
              "target" => parsed,
              "tolerance" => tolerance
            },
            else: %{
              "id" => "expected_#{index + 1}",
              "type" => "json_value",
              "path" => path(field["key"]),
              "allowed_values" => [parsed],
              "numeric_comparison" => "strict"
            }

        {:cont,
         {:ok, acc ++ [%{key: field["key"], value: parsed, tolerance: tolerance, check: check}]}}
      else
        _ ->
          {:halt,
           {:error,
            "Complete #{field["key"]} as #{field["type"]}. Numeric targets must be valid JSON numbers (for example 12.5, not 12.) with non-negative tolerance; magnitude ≤1,000,000. Strings allow up to 120 bytes; boolean values must be explicitly true or false."}}
      end
    end)
  end

  defp scalar("string", value) when byte_size(value) <= 120, do: {:ok, value}
  defp scalar("boolean", "true"), do: {:ok, true}
  defp scalar("boolean", "false"), do: {:ok, false}

  defp scalar(type, value) when type in ~w(number integer) do
    with {:ok, number} when is_number(number) <- Jason.decode(value),
         true <- abs(number) <= 1_000_000 and (type != "integer" or is_integer(number)) do
      {:ok, number}
    else
      _ -> :error
    end
  end

  defp scalar(_, _), do: :error

  defp tolerance(type, value) when type in ~w(number integer) do
    case scalar("number", value) do
      {:ok, number} when number >= 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp tolerance(_, ""), do: {:ok, 0}
  defp tolerance(_, _), do: :error
  defp wrong_value(value, _) when is_binary(value), do: value <> " (wrong)"
  defp wrong_value(value, _) when is_boolean(value), do: not value
  defp wrong_value(value, tolerance) when is_integer(value), do: value + trunc(tolerance) + 2
  defp wrong_value(value, tolerance), do: value + tolerance + 2
  defp path(key), do: "/" <> key
end
