defmodule SilentRegression.GuidedSetups.TextRecipe do
  @moduledoc "Normalized literal alternatives; neither paraphrase nor contradiction detection."
  alias SilentRegression.GuidedSetups.Recipes
  def empty, do: %{"requiredText" => "", "prohibitedText" => ""}
  def raw_settings?(settings), do: Recipes.strings?(settings, Map.keys(empty()))

  def prepare(raw) do
    required = Recipes.lines(raw["settings"]["requiredText"])
    prohibited = Recipes.lines(raw["settings"]["prohibitedText"])
    expected = Enum.map(raw["cases"], &Recipes.lines(&1["expected"]))

    if Recipes.literals?(required, true) and Recipes.literals?(prohibited, true) and
         required ++ prohibited != [] and expected != [] and
         Enum.all?(expected, &Recipes.literals?/1) do
      rules =
        if(required == [],
          do: [],
          else: [
            %{"id" => "required_language", "type" => "required_text", "alternatives" => required}
          ]
        ) ++
          if(prohibited == [],
            do: [],
            else: [
              %{
                "id" => "prohibited_language",
                "type" => "forbidden_text",
                "alternatives" => prohibited
              }
            ]
          )

      cases =
        Enum.with_index(raw["cases"], fn row, index ->
          Recipes.input(row, index, [
            %{
              "id" => "expected_text",
              "type" => "required_text",
              "alternatives" => Enum.at(expected, index)
            }
          ])
        end)

      candidates =
        Enum.with_index(expected)
        |> Enum.flat_map(fn {alternatives, index} ->
          good = Enum.join(Enum.take(required, 1) ++ Enum.take(alternatives, 1), ". ")
          shared_only = Enum.join(Enum.take(required, 1), " ")

          wrong =
            if Enum.any?(
                 alternatives,
                 &SilentRegression.Contracts.Text.contains_literal?(shared_only, &1)
               ), do: "", else: shared_only

          [
            {index, good, "Required shared language and this input's literal answer."},
            {index, wrong, "Missing case-specific literal answer."}
          ]
        end)

      good = candidates |> hd() |> elem(1)

      negatives =
        Enum.map(prohibited, &{0, good <> " " <> &1, "Explicit prohibited alternative."})

      {:ok, rules, cases,
       candidates ++ negatives ++ [{0, "", "Missing shared required language."}]}
    else
      Recipes.error(
        "Configure required or prohibited shared text and a known literal answer for every example. Each list accepts 1–8 distinct normalized alternatives of 120 bytes or less (blank shared lists may be left unused). One required alternative is enough; any prohibited alternative fails. No paraphrases are inferred."
      )
    end
  end
end
