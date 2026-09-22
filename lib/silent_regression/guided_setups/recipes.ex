defmodule SilentRegression.GuidedSetups.Recipes do
  @moduledoc "Versioned, allowlisted guided recipes. Routing v1 remains unchanged."
  alias SilentRegression.GuidedSetups.{
    Draft,
    JsonRecipe,
    Proof,
    Routing,
    SourcesRecipe,
    TextRecipe
  }

  alias SilentRegression.Contracts.Text

  def keys, do: ~w(routing json sources text)
  def empty("routing"), do: Routing.empty()

  def empty(recipe) when recipe in ~w(json sources text),
    do: Routing.empty() |> Map.delete("labelsText") |> Map.put("settings", module(recipe).empty())

  def template("routing"), do: "classification"
  def template("json"), do: "structured_json"
  def template("sources"), do: "grounded_answer"
  def template("text"), do: "required_text"

  def validate_raw("routing", raw), do: Routing.validate_raw(raw)

  def validate_raw(recipe, raw) when recipe in ~w(json sources text) and is_map(raw) do
    with true <- not Map.has_key?(raw, "labelsText"),
         true <- module(recipe).raw_settings?(raw["settings"]),
         :ok <- Routing.validate_raw(raw |> Map.delete("settings") |> Map.put("labelsText", "")),
         {:ok, size} <- SilentRegression.Monitors.JsonValue.encoded_size(raw),
         true <- size <= 240_000 do
      :ok
    else
      _ -> {:error, :invalid_draft}
    end
  end

  def validate_raw(_, _), do: {:error, :invalid_draft}

  def compile(%Draft{recipe_version: 1, recipe: recipe, raw: raw}), do: compile(recipe, raw)
  def compile(_), do: error("This saved recipe version is not supported.")

  def compile("routing", raw) do
    with {:ok, compiled} <- Routing.compile(raw) do
      # Add fixture metadata, without changing any Routing v1 fingerprint or judgment.
      proof =
        Enum.map(
          compiled.proof,
          &Map.put(&1, :failed_rule_ids, if(&1.shared == "fail", do: ["allowed_label"], else: []))
        )

      {:ok, Map.put(compiled, :proof, proof)}
    end
  end

  def compile(recipe, raw) when recipe in ~w(json sources text) do
    with :ok <- validate_raw(recipe, raw),
         {:ok, config} <- Routing.configuration(raw),
         {:ok, rules, cases, candidates} <- module(recipe).prepare(raw) do
      Proof.compile(recipe, config, rules, cases, candidates)
    else
      {:error, :invalid_draft} ->
        error(
          "Unsupported recipe fields or draft size. Use the bounded editor; JSON Schema and arbitrary rules cannot be imported here."
        )

      error ->
        error
    end
  end

  def compile(_, _), do: error("Choose a supported recipe.")

  def summary(%{"checks" => checks}), do: Enum.map_join(checks, "\n", &summary_check/1)
  def summary(_), do: "No case-specific expectation configured."

  defp summary_check(%{"type" => "label", "allowed_values" => values}),
    do: Enum.join(values, " or ")

  defp summary_check(%{"type" => "json_value"} = check),
    do:
      "#{check["path"]} = #{Enum.map_join(check["allowed_values"], " or ", &Jason.encode!/1)} (#{check["numeric_comparison"]})"

  defp summary_check(%{"type" => "json_number"} = check),
    do: "#{check["path"]}: #{check["target"]} ± #{check["tolerance"]} (inclusive)"

  defp summary_check(%{"type" => "source_ids"} = check),
    do:
      "Required IDs: #{Enum.join(check["required"], ", ")}; allowed IDs: #{Enum.join(check["allowed"], ", ")}. Bracket syntax only."

  defp summary_check(%{"type" => "required_text", "alternatives" => values}),
    do: "Contains one literal alternative: #{Enum.join(values, " OR ")}"

  defp summary_check(check), do: Jason.encode!(check)

  def input(row, index, checks) do
    %{
      case_key: row["key"],
      name: row["name"],
      position: index,
      status: "active",
      input_variables: row["variables"],
      frozen_context: row["context"],
      expectation_schema_version: SilentRegression.CaseExpectations.schema_version(),
      expectation: %{"checks" => checks}
    }
  end

  def lines(text),
    do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  def literals?(values, allow_empty \\ false) do
    is_list(values) and length(values) <= 8 and (allow_empty or values != []) and
      Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 120 and Text.normalize(&1) != "")) and
      Enum.uniq_by(values, &Text.normalize/1) == values
  end

  def strings?(settings, keys) when is_map(settings) do
    Enum.sort(Map.keys(settings)) == Enum.sort(keys) and
      Enum.all?(
        keys,
        &(is_binary(settings[&1]) and String.valid?(settings[&1]) and
            byte_size(settings[&1]) <= 4000)
      )
  end

  def strings?(_, _), do: false
  def error(message), do: {:error, {:examples, message}}
  defp module("json"), do: JsonRecipe
  defp module("sources"), do: SourcesRecipe
  defp module("text"), do: TextRecipe
end
