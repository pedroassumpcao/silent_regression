defmodule SilentRegression.GuidedSetups.SourcesRecipe do
  @moduledoc "Declared bracketed source sets and optional literal trailing attribution."
  alias SilentRegression.GuidedSetups.Recipes

  def empty,
    do: %{
      "allowedText" => "",
      "requiredText" => "",
      "factText" => "",
      "factSourceId" => "",
      "distance" => "100"
    }

  def raw_settings?(settings), do: Recipes.strings?(settings, Map.keys(empty()))

  def prepare(raw) do
    settings = raw["settings"]
    allowed = Recipes.lines(settings["allowedText"])
    required = Recipes.lines(settings["requiredText"])
    facts = Recipes.lines(settings["factText"])
    source = settings["factSourceId"]

    with true <- ids?(allowed) and ids?(required, true) and Enum.all?(required, &(&1 in allowed)),
         true <- Recipes.literals?(facts, true),
         {distance, ""} when distance in 1..500 <- Integer.parse(settings["distance"]),
         true <- (facts == [] and source == "") or (facts != [] and source in allowed),
         true <- raw["cases"] != [],
         sets <- Enum.map(raw["cases"], &Recipes.lines(&1["expected"])),
         true <-
           Enum.all?(
             sets,
             &(ids?(&1) and Enum.all?(&1, fn id -> id in allowed end) and
                 Enum.all?(required, fn id -> id in &1 end) and (facts == [] or source in &1))
           ) do
      rules =
        [
          %{
            "id" => "allowed_sources",
            "type" => "allowed_source_ids",
            "source_ids" => allowed,
            "require_at_least_one" => true
          }
        ] ++
          if(required == [],
            do: [],
            else: [
              %{
                "id" => "required_sources",
                "type" => "required_source_ids",
                "source_ids" => required
              }
            ]
          ) ++
          if(facts == [],
            do: [],
            else: [
              %{
                "id" => "fact_source",
                "type" => "fact_citation",
                "fact_alternatives" => facts,
                "source_ids" => [source],
                "max_distance_characters" => distance
              }
            ]
          )

      cases =
        Enum.with_index(raw["cases"], fn row, index ->
          ids = Enum.at(sets, index)

          Recipes.input(row, index, [
            %{
              "id" => "expected_sources",
              "type" => "source_ids",
              "required" => ids,
              "allowed" => ids,
              "require_at_least_one" => true
            }
          ])
        end)

      candidates =
        Enum.with_index(sets)
        |> Enum.flat_map(fn {ids, index} ->
          other = Enum.find(allowed, &(&1 not in ids))

          {wrong, purpose} =
            if other,
              do: {ids ++ [other], "A globally allowed source is wrong for this input."},
              else: {tl(ids), "A required case-specific source is missing."}

          [
            {index, output(ids, facts, source), "Declared source set and attribution."},
            {index, output(wrong, facts, source), purpose}
          ]
        end)

      unknown = Enum.find(1..9, &("unlisted-#{&1}" not in allowed))

      negatives = [
        {0, "[unlisted-#{unknown}]", "A source outside the allowed set."},
        {0, "No citation", "No bracketed source citation."}
      ]

      negatives =
        if facts == [],
          do: negatives,
          else:
            negatives ++
              [
                {0, Enum.map_join(hd(sets), " ", &"[#{&1}]") <> " " <> hd(facts),
                 "Source before the declared fact: not trailing attribution."}
              ]

      {:ok, rules, cases, candidates ++ negatives}
    else
      _ ->
        Recipes.error(
          "Enter 1–8 distinct allowed source IDs and a non-empty exact source set per example, one ID per line. Required and attributed IDs must be in every example's set. IDs use letters/digits and . _ : - (40 characters max). Attribution needs literal alternatives, one allowed source and distance 1–500. Empty attribution requires an empty attribution source."
        )
    end
  end

  defp ids?(ids, allow_empty \\ false),
    do:
      length(ids) <= 8 and (allow_empty or ids != []) and Enum.uniq(ids) == ids and
        Enum.all?(ids, &Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,39}\z/, &1))

  defp output(ids, facts, source) do
    phrase = if facts == [], do: "Sample answer", else: hd(facts)
    ordered = if source in ids, do: [source | Enum.reject(ids, &(&1 == source))], else: ids
    phrase <> " " <> Enum.map_join(ordered, " ", &"[#{&1}]")
  end
end
