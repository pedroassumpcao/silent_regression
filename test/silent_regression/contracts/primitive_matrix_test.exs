defmodule SilentRegression.Contracts.PrimitiveMatrixTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Contracts

  @evaluated_at ~U[2026-09-15 12:00:00.000000Z]

  test "every primitive has positive, negative, malformed, boundary, and adversarial coverage" do
    fixtures = fixtures()

    assert fixtures |> Enum.map(& &1.type) |> Enum.sort() ==
             Contracts.Parser.rule_types() |> Enum.sort()

    for fixture <- fixtures do
      assert_evaluation(fixture.type, "positive", fixture.positive, :pass)
      assert_evaluation(fixture.type, "negative", fixture.negative, :fail)
      assert_malformed(fixture.type, fixture.malformed)
      assert_evaluation(fixture.type, "boundary", fixture.boundary, fixture.boundary_status)

      assert_evaluation(
        fixture.type,
        "adversarial",
        fixture.adversarial,
        fixture.adversarial_status
      )
    end
  end

  defp fixtures do
    deep_64 = String.duplicate("[", 64) <> "0" <> String.duplicate("]", 64)
    deep_65 = "[" <> deep_64 <> "]"
    long_alternative = String.duplicate("x", 500)

    [
      %{
        type: "json_valid",
        positive: {json_valid("rule"), "{}"},
        negative: {json_valid("rule"), "{"},
        malformed: {Map.put(json_valid("rule"), "allow_fence", true), "unexpected_fields"},
        boundary: {json_valid("rule"), deep_64},
        boundary_status: :pass,
        adversarial: {json_valid("rule"), ~s({"key":1,"key":2})},
        adversarial_status: :fail
      },
      %{
        type: "json_path_exists",
        positive:
          {%{"id" => "rule", "type" => "json_path_exists", "path" => "/item"}, ~s({"item":1})},
        negative: {%{"id" => "rule", "type" => "json_path_exists", "path" => "/item"}, "{}"},
        malformed:
          {%{"id" => "rule", "type" => "json_path_exists", "path" => "item"},
           "invalid_json_pointer"},
        boundary: {%{"id" => "rule", "type" => "json_path_exists", "path" => ""}, "null"},
        boundary_status: :pass,
        adversarial: {%{"id" => "rule", "type" => "json_path_exists", "path" => "/01"}, "[0,1]"},
        adversarial_status: :fail
      },
      %{
        type: "json_path_type",
        positive:
          {%{
             "id" => "rule",
             "type" => "json_path_type",
             "path" => "/value",
             "expected_type" => "string"
           }, ~s({"value":"ok"})},
        negative:
          {%{
             "id" => "rule",
             "type" => "json_path_type",
             "path" => "/value",
             "expected_type" => "string"
           }, ~s({"value":1})},
        malformed:
          {%{
             "id" => "rule",
             "type" => "json_path_type",
             "path" => "",
             "expected_type" => "decimal"
           }, "unsupported_value"},
        boundary:
          {%{"id" => "rule", "type" => "json_path_type", "path" => "", "expected_type" => "null"},
           "null"},
        boundary_status: :pass,
        adversarial:
          {%{
             "id" => "rule",
             "type" => "json_path_type",
             "path" => "",
             "expected_type" => "integer"
           }, "1.0"},
        adversarial_status: :fail
      },
      %{
        type: "json_path_equals",
        positive: {json_equals("rule", "/value", "ok", "strict"), ~s({"value":"ok"})},
        negative: {json_equals("rule", "/value", "ok", "strict"), ~s({"value":"no"})},
        malformed: {json_equals("rule", "", 1, "approximately"), "unsupported_value"},
        boundary: {json_equals("rule", "", nil, "strict"), "null"},
        boundary_status: :pass,
        adversarial: {json_equals("rule", "", 1, "strict"), "1.0"},
        adversarial_status: :fail
      },
      %{
        type: "json_path_allowed_values",
        positive: {json_allowed("rule", ["open", "closed"]), ~s("open")},
        negative: {json_allowed("rule", ["open", "closed"]), ~s("pending")},
        malformed:
          {%{
             "id" => "rule",
             "type" => "json_path_allowed_values",
             "path" => "",
             "allowed_values" => [],
             "numeric_comparison" => "strict"
           }, "invalid_allowed_values"},
        boundary: {json_allowed("rule", [false, nil]), "null"},
        boundary_status: :pass,
        adversarial: {json_allowed("rule", [1]), "1.0"},
        adversarial_status: :fail
      },
      %{
        type: "json_path_number",
        positive: {json_number("rule", %{"minimum" => 0, "maximum" => 10}), "5"},
        negative: {json_number("rule", %{"minimum" => 0, "maximum" => 10}), "11"},
        malformed: {json_number("rule", %{"target" => 5}), "incomplete_tolerance"},
        boundary:
          {json_number("rule", %{"minimum" => 0, "maximum" => 10, "target" => 5, "tolerance" => 5}),
           "10"},
        boundary_status: :pass,
        adversarial: {json_number("rule", %{"minimum" => 0}), ~s("5")},
        adversarial_status: :fail
      },
      %{
        type: "classification",
        positive: {classification("rule", ["needs review"]), "NEEDS—REVIEW"},
        negative: {classification("rule", ["needs review"]), "approved"},
        malformed:
          {classification("rule", ["Needs Review", "needs-review"]), "duplicate_alternative"},
        boundary: {classification("rule", ["x"]), "X"},
        boundary_status: :pass,
        adversarial: {classification("rule", ["review"]), "review soon"},
        adversarial_status: :fail
      },
      %{
        type: "required_text",
        positive: {required_text("rule", ["six weeks"]), "The term is six weeks."},
        negative: {required_text("rule", ["six weeks"]), "No term is given."},
        malformed: {required_text("rule", [""]), "invalid_alternative"},
        boundary: {required_text("rule", [long_alternative]), long_alternative},
        boundary_status: :pass,
        adversarial: {required_text("rule", ["six weeks"]), "The term is sixteen weeks."},
        adversarial_status: :fail
      },
      %{
        type: "forbidden_text",
        positive: {forbidden_text("rule", ["six weeks"]), "No term is given."},
        negative: {forbidden_text("rule", ["six weeks"]), "The term is six weeks."},
        malformed: {forbidden_text("rule", [" "]), "invalid_alternative"},
        boundary: {forbidden_text("rule", ["x"]), "y"},
        boundary_status: :pass,
        adversarial: {forbidden_text("rule", ["six weeks"]), "The term is sixteen weeks."},
        adversarial_status: :pass
      },
      %{
        type: "required_source_ids",
        positive: {required_sources("rule", ["doc-1"]), "Supported [doc-1]."},
        negative: {required_sources("rule", ["doc-1"]), "Unsupported."},
        malformed: {required_sources("rule", ["bad source"]), "invalid_source_id"},
        boundary: {required_sources("rule", ["x"]), "[x]"},
        boundary_status: :pass,
        adversarial: {required_sources("rule", ["doc-1"]), "[doc-1](https://example.test)"},
        adversarial_status: :fail
      },
      %{
        type: "allowed_source_ids",
        positive: {allowed_sources("rule", ["doc-1"], true), "Supported [doc-1]."},
        negative: {allowed_sources("rule", ["doc-1"], true), "Supported [fake-2]."},
        malformed:
          {%{
             "id" => "rule",
             "type" => "allowed_source_ids",
             "source_ids" => ["doc-1"],
             "require_at_least_one" => "true"
           }, "invalid_type"},
        boundary: {allowed_sources("rule", ["doc-1"], false), "No citations."},
        boundary_status: :pass,
        adversarial: {allowed_sources("rule", ["doc-1"], true), "[doc-1](https://example.test)"},
        adversarial_status: :fail
      },
      %{
        type: "fact_citation",
        positive: {fact_citation("rule", 30), "Purchase approved [approval-1]."},
        negative: {fact_citation("rule", 30), "Purchase approved [other-1]."},
        malformed:
          {%{fact_citation("rule", 30) | "max_distance_characters" => 0}, "invalid_distance"},
        boundary: {fact_citation("rule", 18), "Purchase approved [approval-1]."},
        boundary_status: :pass,
        adversarial: {fact_citation("rule", 30), "Purchase approved. [approval-1]"},
        adversarial_status: :fail
      },
      %{
        type: "required_abstention",
        positive: {abstention("rule", ["not specified"]), "The date is not specified."},
        negative: {abstention("rule", ["not specified"]), "The shipment is pending."},
        malformed: {abstention("rule", []), "invalid_alternatives"},
        boundary: {abstention("rule", ["no"]), "No."},
        boundary_status: :pass,
        adversarial: {abstention("rule", ["no"]), "Not available."},
        adversarial_status: :fail
      },
      %{
        type: "length",
        positive: {length_rule("rule", "words", 1, 3), "one two"},
        negative: {length_rule("rule", "words", 1, 3), "one two three four"},
        malformed:
          {%{"id" => "rule", "type" => "length", "unit" => "words"}, "missing_length_bound"},
        boundary: {length_rule("rule", "words", 1, 3), "one two three"},
        boundary_status: :pass,
        adversarial: {length_rule("rule", "graphemes", 1, 1), "e\u0301"},
        adversarial_status: :pass
      },
      %{
        type: "all",
        positive:
          {group("rule", "all", [required_text("a", ["one"]), required_text("b", ["two"])]),
           "one two"},
        negative:
          {group("rule", "all", [required_text("a", ["one"]), required_text("b", ["two"])]),
           "one"},
        malformed: {group("rule", "all", []), "invalid_group"},
        boundary: {group("rule", "all", [required_text("a", ["one"])]), "one"},
        boundary_status: :pass,
        adversarial:
          {group("rule", "all", [json_valid("json"), required_text("zero", ["0"])]), deep_65},
        adversarial_status: :evaluator_error
      },
      %{
        type: "any",
        positive:
          {group("rule", "any", [required_text("a", ["one"]), required_text("b", ["two"])]),
           "two"},
        negative:
          {group("rule", "any", [required_text("a", ["one"]), required_text("b", ["two"])]),
           "three"},
        malformed: {group("rule", "any", []), "invalid_group"},
        boundary: {group("rule", "any", [required_text("a", ["one"])]), "three"},
        boundary_status: :fail,
        adversarial:
          {group("rule", "any", [json_valid("json"), required_text("zero", ["0"])]), deep_65},
        adversarial_status: :evaluator_error
      },
      %{
        type: "not",
        positive: {not_rule("rule", required_text("child", ["blocked"])), "allowed"},
        negative: {not_rule("rule", required_text("child", ["blocked"])), "blocked"},
        malformed: {%{"id" => "rule", "type" => "not"}, "missing_fields"},
        boundary: {not_rule("rule", required_text("child", ["x"])), "y"},
        boundary_status: :pass,
        adversarial: {not_rule("rule", json_valid("json")), deep_65},
        adversarial_status: :evaluator_error
      }
    ]
  end

  defp assert_evaluation(type, category, {rule, output}, expected_status) do
    assert {:ok, contract} = Contracts.parse_contract(contract(rule)), "#{type} #{category} parse"

    assert {:ok, observation} =
             Contracts.new_observation(%{"id" => "fixture", "output_text" => output})

    assert {:ok, evaluation} =
             Contracts.evaluate(contract, observation,
               evaluation_id: "evaluation",
               evaluated_at: @evaluated_at
             )

    assert evaluation.status == expected_status, "#{type} #{category} outcome"
  end

  defp assert_malformed(type, {rule, expected_code}) do
    assert {:error, %{"code" => ^expected_code}} = Contracts.parse_contract(contract(rule)),
           "#{type} malformed contract"
  end

  defp contract(rule) do
    %{
      "schema_version" => 1,
      "contract_id" => "matrix-contract",
      "contract_version" => 1,
      "monitor_id" => "matrix-monitor",
      "root" => rule
    }
  end

  defp json_valid(id), do: %{"id" => id, "type" => "json_valid"}

  defp json_equals(id, path, expected, comparison) do
    %{
      "id" => id,
      "type" => "json_path_equals",
      "path" => path,
      "expected" => expected,
      "numeric_comparison" => comparison
    }
  end

  defp json_allowed(id, values) do
    %{
      "id" => id,
      "type" => "json_path_allowed_values",
      "path" => "",
      "allowed_values" => values,
      "numeric_comparison" => "strict"
    }
  end

  defp json_number(id, bounds) do
    Map.merge(%{"id" => id, "type" => "json_path_number", "path" => ""}, bounds)
  end

  defp classification(id, values),
    do: %{"id" => id, "type" => "classification", "allowed_values" => values}

  defp required_text(id, values),
    do: %{"id" => id, "type" => "required_text", "alternatives" => values}

  defp forbidden_text(id, values),
    do: %{"id" => id, "type" => "forbidden_text", "alternatives" => values}

  defp required_sources(id, values),
    do: %{"id" => id, "type" => "required_source_ids", "source_ids" => values}

  defp allowed_sources(id, values, require_at_least_one) do
    %{
      "id" => id,
      "type" => "allowed_source_ids",
      "source_ids" => values,
      "require_at_least_one" => require_at_least_one
    }
  end

  defp fact_citation(id, max_distance) do
    %{
      "id" => id,
      "type" => "fact_citation",
      "fact_alternatives" => ["purchase approved"],
      "source_ids" => ["approval-1"],
      "max_distance_characters" => max_distance
    }
  end

  defp abstention(id, alternatives) do
    %{"id" => id, "type" => "required_abstention", "alternatives" => alternatives}
  end

  defp length_rule(id, unit, minimum, maximum) do
    %{
      "id" => id,
      "type" => "length",
      "unit" => unit,
      "minimum" => minimum,
      "maximum" => maximum
    }
  end

  defp group(id, type, rules), do: %{"id" => id, "type" => type, "rules" => rules}
  defp not_rule(id, rule), do: %{"id" => id, "type" => "not", "rule" => rule}
end
