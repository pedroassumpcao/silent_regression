defmodule SilentRegression.ContractAuthoring.Templates do
  @moduledoc """
  Frozen workflow-shaped starter contracts for the private-alpha authoring UI.

  Defaults are examples, not inferred customer requirements. Their stable rule
  IDs make accepted, edited, removed, and added suggestions measurable.
  """

  @templates [
    %{
      "key" => "structured_json",
      "title" => "Structured JSON",
      "description" =>
        "Validate raw JSON, required paths, exact values, types, and numeric bounds.",
      "best_for" => "Extraction, structured generation, and machine-consumed responses",
      "limitation" =>
        "Checks declared structure and values; it does not infer whether extracted facts are true.",
      "root" => %{
        "id" => "contract",
        "type" => "all",
        "rules" => [
          %{"id" => "valid_json", "type" => "json_valid"},
          %{"id" => "required_field", "type" => "json_path_exists", "path" => "/field"}
        ]
      }
    },
    %{
      "key" => "classification",
      "title" => "Classification or routing",
      "description" => "Require the whole normalized output to be one approved label.",
      "best_for" => "Triage, routing, moderation labels, and finite decisions",
      "limitation" =>
        "Rejects extra words and does not judge whether the selected label is semantically correct.",
      "root" => %{
        "id" => "contract",
        "type" => "all",
        "rules" => [
          %{
            "id" => "allowed_label",
            "type" => "classification",
            "allowed_values" => ["approved", "rejected"]
          },
          %{
            "id" => "label_length",
            "type" => "length",
            "severity" => "warning",
            "unit" => "words",
            "minimum" => 1,
            "maximum" => 2
          }
        ]
      }
    },
    %{
      "key" => "grounded_answer",
      "title" => "Grounded answer with citations",
      "description" =>
        "Require approved bracketed sources and attach a declared fact to its supporting source.",
      "best_for" => "RAG answers, support responses, and policy guidance with fixed source IDs",
      "limitation" =>
        "Citation placement is syntactic and checks only facts and source IDs you explicitly configure.",
      "root" => %{
        "id" => "contract",
        "type" => "all",
        "rules" => [
          %{
            "id" => "required_sources",
            "type" => "required_source_ids",
            "source_ids" => ["source-1"]
          },
          %{
            "id" => "allowed_sources",
            "type" => "allowed_source_ids",
            "source_ids" => ["source-1"],
            "require_at_least_one" => true
          },
          %{
            "id" => "fact_source",
            "type" => "fact_citation",
            "fact_alternatives" => ["supported statement"],
            "source_ids" => ["source-1"],
            "max_distance_characters" => 100
          }
        ]
      }
    },
    %{
      "key" => "required_text",
      "title" => "Required and prohibited text",
      "description" =>
        "Require approved literal alternatives and reject explicit prohibited alternatives.",
      "best_for" => "Policy language, disclosures, abstention phrases, and prohibited claims",
      "limitation" =>
        "Matches normalized literal phrases only; it does not understand paraphrases or contradictions.",
      "root" => %{
        "id" => "contract",
        "type" => "all",
        "rules" => [
          %{
            "id" => "required_language",
            "type" => "required_text",
            "alternatives" => ["required phrase"]
          },
          %{
            "id" => "prohibited_language",
            "type" => "forbidden_text",
            "alternatives" => ["forbidden phrase"]
          }
        ]
      }
    }
  ]

  @spec all() :: [map()]
  def all, do: @templates

  @spec fetch(String.t()) :: {:ok, map()} | {:error, :unknown_template}
  def fetch(key) when is_binary(key) do
    case Enum.find(@templates, &(&1["key"] == key)) do
      nil -> {:error, :unknown_template}
      template -> {:ok, template}
    end
  end

  def fetch(_key), do: {:error, :unknown_template}

  @spec usage(String.t(), map()) :: {:ok, map()} | {:error, :unknown_template}
  def usage(key, %{"type" => "all", "rules" => rules}) when is_list(rules) do
    with {:ok, template} <- fetch(key) do
      suggested_rules = template["root"]["rules"]
      actual_by_id = Map.new(rules, &{&1["id"], &1})
      suggested_ids = MapSet.new(suggested_rules, & &1["id"])

      suggested_usage =
        Enum.map(suggested_rules, fn suggested ->
          actual = Map.get(actual_by_id, suggested["id"])

          %{
            "suggestion_id" => suggested["id"],
            "rule_id" => if(actual, do: actual["id"], else: nil),
            "rule_type" => suggested["type"],
            "action" => suggestion_action(suggested, actual)
          }
        end)

      added_usage =
        rules
        |> Enum.reject(&MapSet.member?(suggested_ids, &1["id"]))
        |> Enum.map(fn rule ->
          %{
            "suggestion_id" => nil,
            "rule_id" => rule["id"],
            "rule_type" => rule["type"],
            "action" => "added"
          }
        end)

      {:ok,
       %{
         "template_key" => key,
         "rules" => suggested_usage ++ added_usage
       }}
    end
  end

  def usage(key, _root) do
    with {:ok, _template} <- fetch(key), do: {:error, :invalid_root}
  end

  defp suggestion_action(_suggested, nil), do: "removed"
  defp suggestion_action(suggested, suggested), do: "accepted"
  defp suggestion_action(_suggested, _actual), do: "edited"
end
