defmodule SilentRegression.Contracts.EvaluatorTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Contracts
  alias SilentRegression.Contracts.{Evaluation, Limits, Observation, RuleResult}

  @evaluated_at ~U[2026-09-15 12:00:00.000000Z]

  describe "JSON primitives" do
    test "distinguishes valid JSON, ordinary JSON failures, and evaluator resource errors" do
      assert_result(json_valid(), ~s({"ready":true}), :pass, "valid_json")
      assert_result(json_valid(), "```json\n{}\n```", :fail, "invalid_json")
      assert_result(json_valid(), ~s({"ready":true,"ready":false}), :fail, "duplicate_object_key")
      assert_result(json_valid(), Jason.encode!(String.duplicate("[", 100)), :pass, "valid_json")

      deeply_nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
      assert_result(json_valid(), deeply_nested, :evaluator_error, "json_nesting_too_deep")
    end

    test "resolves RFC 6901 pointers and reports missing or invalid traversals" do
      rule = %{"id" => "sku", "type" => "json_path_exists", "path" => "/items/0/a~1b"}
      assert_result(rule, ~s({"items":[{"a/b":"A-1"}]}), :pass, "json_path_present")
      assert_result(rule, ~s({"items":[]}), :fail, "json_path_missing")

      invalid_index = %{rule | "path" => "/items/01"}
      assert_result(invalid_index, ~s({"items":[1]}), :fail, "json_path_invalid_array_index")

      wrong_container = %{rule | "path" => "/items/0/value"}
      assert_result(wrong_container, ~s({"items":[1]}), :fail, "json_path_wrong_container")
    end

    test "checks root and nested JSON types without treating integers as floats" do
      integer_rule = %{
        "id" => "count",
        "type" => "json_path_type",
        "path" => "/count",
        "expected_type" => "integer"
      }

      number_rule = %{integer_rule | "id" => "number", "expected_type" => "number"}

      assert_result(integer_rule, ~s({"count":2}), :pass, "json_type_matched")
      assert_result(integer_rule, ~s({"count":2.0}), :fail, "json_type_mismatch")
      assert_result(number_rule, ~s({"count":2.0}), :pass, "json_type_matched")

      root_rule = %{integer_rule | "id" => "root_array", "path" => "", "expected_type" => "array"}
      assert_result(root_rule, "[]", :pass, "json_type_matched")
    end

    test "uses explicit strict or mathematical equality recursively" do
      base = %{
        "id" => "payload",
        "type" => "json_path_equals",
        "path" => "/payload",
        "expected" => %{"count" => 2, "order" => ["a", "b"]},
        "numeric_comparison" => "strict"
      }

      output = ~s({"payload":{"order":["a","b"],"count":2.0}})
      assert_result(base, output, :fail, "json_value_mismatch")

      assert_result(
        %{base | "numeric_comparison" => "mathematical"},
        output,
        :pass,
        "json_value_matched"
      )

      reordered = ~s({"payload":{"count":2,"order":["b","a"]}})
      assert_result(base, reordered, :fail, "json_value_mismatch")
    end

    test "accepts false and null as configured allowed values" do
      rule = %{
        "id" => "decision",
        "type" => "json_path_allowed_values",
        "path" => "/decision",
        "allowed_values" => [false, nil],
        "numeric_comparison" => "strict"
      }

      assert_result(rule, ~s({"decision":false}), :pass, "json_value_allowed")
      assert_result(rule, ~s({"decision":null}), :pass, "json_value_allowed")
      assert_result(rule, ~s({"decision":true}), :fail, "json_value_not_allowed")
    end

    test "treats range and tolerance endpoints as inclusive" do
      rule = %{
        "id" => "confidence",
        "type" => "json_path_number",
        "path" => "/confidence",
        "minimum" => 0.8,
        "maximum" => 1.0,
        "target" => 0.9,
        "tolerance" => 0.1
      }

      for value <- [0.8, 0.9, 1.0] do
        assert_result(
          rule,
          Jason.encode!(%{"confidence" => value}),
          :pass,
          "json_number_within_bounds"
        )
      end

      for value <- [0.799, 1.001] do
        assert_result(
          rule,
          Jason.encode!(%{"confidence" => value}),
          :fail,
          "json_number_out_of_bounds"
        )
      end

      assert_result(rule, ~s({"confidence":"high"}), :fail, "json_type_mismatch")
    end
  end

  describe "classification and literal text primitives" do
    test "carries configured rule severity into explainable results" do
      critical_rule = %{
        "id" => "route",
        "type" => "classification",
        "allowed_values" => ["approved"]
      }

      observation = observation!("rejected")

      assert {:ok, default_evaluation} =
               critical_rule
               |> parse!()
               |> Contracts.evaluate(observation, evaluated_at: @evaluated_at)

      assert [%RuleResult{severity: :critical, status: :fail}] =
               default_evaluation.rule_results

      contract = parse!(Map.put(critical_rule, "severity", "warning"))

      assert {:ok, evaluation} =
               Contracts.evaluate(contract, observation, evaluated_at: @evaluated_at)

      assert [%RuleResult{severity: :warning, status: :fail}] = evaluation.rule_results
    end

    test "normalizes labels while requiring a whole-label match" do
      rule = %{
        "id" => "route",
        "type" => "classification",
        "allowed_values" => ["Needs Review", "Approved"]
      }

      assert_result(rule, "  NEEDS—REVIEW\n", :pass, "classification_allowed")
      assert_result(rule, "Needs Review Soon", :fail, "classification_not_allowed")
    end

    test "matches complete normalized token sequences for required and forbidden text" do
      required = %{
        "id" => "duration",
        "type" => "required_text",
        "alternatives" => ["six weeks"]
      }

      forbidden = %{required | "id" => "prohibited", "type" => "forbidden_text"}

      assert_result(required, "The term is SIX—WEEKS.", :pass, "required_text_present")
      assert_result(required, "The term is sixteen weeks.", :fail, "required_text_missing")
      assert_result(forbidden, "The term is sixteen weeks.", :pass, "forbidden_text_absent")
      assert_result(forbidden, "The term is six weeks.", :fail, "forbidden_text_present")
    end

    test "requires only customer-declared abstention alternatives" do
      rule = %{
        "id" => "unsupported",
        "type" => "required_abstention",
        "alternatives" => ["not specified", "cannot be determined"]
      }

      assert_result(
        rule,
        "The amount is not specified in the supplied policy.",
        :pass,
        "abstention_present"
      )

      assert_result(rule, "The policy discusses employee benefits.", :fail, "abstention_missing")
    end
  end

  describe "citation primitives" do
    test "requires exact bracketed IDs and does not count Markdown links" do
      rule = %{
        "id" => "sources",
        "type" => "required_source_ids",
        "source_ids" => ["policy-1", "table:2"]
      }

      assert_result(
        rule,
        "Allowed [policy-1]. Limit [table:2].",
        :pass,
        "required_source_ids_present"
      )

      assert_result(
        rule,
        "Allowed policy-1. Limit [table:2].",
        :fail,
        "required_source_ids_missing"
      )

      assert_result(
        rule,
        "[policy-1](https://example.test) and [table:2]",
        :fail,
        "required_source_ids_missing"
      )
    end

    test "rejects unconfigured citation IDs and optionally requires one" do
      rule = %{
        "id" => "allowed_sources",
        "type" => "allowed_source_ids",
        "source_ids" => ["guide-1"],
        "require_at_least_one" => true
      }

      assert_result(rule, "The answer [guide-1].", :pass, "source_ids_allowed")
      assert_result(rule, "The answer [invented-9].", :fail, "disallowed_source_id_present")
      assert_result(rule, "The answer has no citation.", :fail, "source_id_missing")

      many_sources = Enum.map_join(1..30, " ", &"[unlisted-#{&1}]")
      result = assert_result(rule, many_sources, :fail, "disallowed_source_id_present")
      assert result.evidence["found_source_ids"]["count"] == 30
      assert result.evidence["found_source_ids"]["truncated"]
      assert length(result.evidence["found_source_ids"]["items"]) == 20
    end

    test "requires an allowed trailing citation in the same bounded sentence segment" do
      rule = %{
        "id" => "approval_source",
        "type" => "fact_citation",
        "fact_alternatives" => ["purchase is approved", "approved purchase"],
        "source_ids" => ["approval-7"],
        "max_distance_characters" => 40
      }

      assert_result(
        rule,
        "The purchase is approved [approval-7].",
        :pass,
        "fact_citation_matched"
      )

      assert_result(rule, "The purchase is approved [other-2].", :fail, "fact_citation_missing")

      assert_result(
        rule,
        "The purchase is approved. [approval-7]",
        :fail,
        "fact_citation_missing"
      )

      too_far = "The purchase is approved " <> String.duplicate("x", 41) <> " [approval-7]."
      assert_result(rule, too_far, :fail, "fact_citation_missing")

      assert_result(
        rule,
        "The request remains pending [approval-7].",
        :fail,
        "cited_fact_missing"
      )
    end
  end

  describe "length and composition" do
    test "counts Unicode graphemes and normalized words at inclusive boundaries" do
      graphemes = %{
        "id" => "characters",
        "type" => "length",
        "unit" => "graphemes",
        "minimum" => 2,
        "maximum" => 2
      }

      words = %{graphemes | "id" => "words", "unit" => "words"}

      assert_result(graphemes, "e\u0301x", :pass, "length_within_bounds")
      assert_result(graphemes, "e\u0301xy", :fail, "length_out_of_bounds")
      assert_result(words, "One—two", :pass, "length_within_bounds")
      assert_result(words, "One two three", :fail, "length_out_of_bounds")
    end

    test "evaluates all, any, and not without hiding child evidence" do
      root = %{
        "id" => "root",
        "type" => "all",
        "rules" => [
          %{
            "id" => "decision",
            "type" => "any",
            "rules" => [
              %{"id" => "approved", "type" => "required_text", "alternatives" => ["approved"]},
              %{"id" => "accepted", "type" => "required_text", "alternatives" => ["accepted"]}
            ]
          },
          %{
            "id" => "not_rejected",
            "type" => "not",
            "rule" => %{
              "id" => "rejected",
              "type" => "required_text",
              "alternatives" => ["rejected"]
            }
          }
        ]
      }

      evaluation = evaluate!(root, "Approved after review.")
      assert evaluation.status == :pass

      assert Enum.map(evaluation.rule_results, & &1.rule_id) == [
               "root",
               "decision",
               "approved",
               "accepted",
               "not_rejected",
               "rejected"
             ]

      assert Enum.find(evaluation.rule_results, &(&1.rule_id == "accepted")).status == :fail
      assert Enum.find(evaluation.rule_results, &(&1.rule_id == "not_rejected")).status == :pass
    end

    test "propagates evaluator errors through composition even when another child passes" do
      root = %{
        "id" => "root",
        "type" => "any",
        "rules" => [
          json_valid(),
          %{"id" => "has_zero", "type" => "required_text", "alternatives" => ["0"]}
        ]
      }

      deeply_nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
      evaluation = evaluate!(root, deeply_nested)

      assert evaluation.status == :evaluator_error
      assert hd(evaluation.rule_results).code == "child_evaluator_error"
      assert evaluation.error["code"] == "rule_evaluator_error"
    end
  end

  describe "evaluation records and bounds" do
    test "is deterministic for fixed provenance and creates a new record when rescored" do
      contract =
        parse!(%{"id" => "required", "type" => "required_text", "alternatives" => ["ready"]})

      observation = observation!("Ready.")
      original = Observation.to_map(observation)

      options = [evaluation_id: "evaluation-fixed", evaluated_at: @evaluated_at]
      assert {:ok, first} = Contracts.evaluate(contract, observation, options)
      assert {:ok, repeated} = Contracts.evaluate(contract, observation, options)
      assert Evaluation.to_map(first) == Evaluation.to_map(repeated)

      assert {:ok, rescored} = Contracts.rescore(contract, observation)
      refute rescored.id == first.id
      assert rescored.rule_results == first.rule_results
      assert Observation.to_map(observation) == original
      assert rescored.observation_id == observation.id
      assert rescored.contract_fingerprint == contract.fingerprint
      assert rescored.evaluator_engine_version == Contracts.evaluator_engine_version()
    end

    test "returns top-level evaluator errors for unsupported versions and unsafe outputs" do
      contract = parse!(json_valid())

      assert {:ok, unavailable} =
               Contracts.evaluate(contract, observation!("{}"),
                 evaluator_engine_version: "deterministic-v2"
               )

      assert unavailable.status == :evaluator_error
      assert unavailable.error["code"] == "unsupported_evaluator_engine_version"
      assert unavailable.rule_results == []

      assert {:ok, invalid_utf8} = Contracts.evaluate(contract, observation!(<<255>>))
      assert invalid_utf8.status == :evaluator_error
      assert invalid_utf8.error["code"] == "invalid_output_utf8"

      oversized = String.duplicate("x", Limits.output_bytes() + 1)
      assert {:ok, too_large} = Contracts.evaluate(contract, observation!(oversized))
      assert too_large.status == :evaluator_error
      assert too_large.error["code"] == "output_too_large"
    end

    test "bounds large expected and actual value evidence" do
      expected = String.duplicate("x", Limits.alternative_bytes())

      rule = %{
        "id" => "large_value",
        "type" => "json_path_equals",
        "path" => "/value",
        "expected" => expected,
        "numeric_comparison" => "strict"
      }

      evaluation = evaluate!(rule, Jason.encode!(%{"value" => String.duplicate("y", 800)}))
      [result] = evaluation.rule_results

      assert result.status == :fail
      assert result.evidence["expected"]["truncated"]
      assert result.evidence["actual"]["truncated"]
      assert byte_size(result.evidence["expected"]["preview"]) <= Limits.evidence_excerpt_bytes()
      assert byte_size(result.evidence["actual"]["preview"]) <= Limits.evidence_excerpt_bytes()
      assert is_binary(Jason.encode!(RuleResult.to_map(result)))
    end

    test "does not contain spike-specific facts or claim drift detection" do
      sources =
        "lib/silent_regression/contracts/*.ex"
        |> Path.wildcard()
        |> Enum.map_join("\n", &File.read!/1)

      for fixture_term <- [
            "Meridian Lantern",
            "Larkspur Bay",
            "tour-schedule",
            "phase-one-budget"
          ] do
        refute sources =~ fixture_term
      end

      refute sources =~ "detects lexical drift"
      refute sources =~ "detects semantic drift"
    end
  end

  defp assert_result(rule, output, expected_status, expected_code) do
    evaluation = evaluate!(rule, output)
    result = Enum.find(evaluation.rule_results, &(&1.rule_id == rule["id"]))

    assert result.status == expected_status
    assert result.code == expected_code
    assert is_binary(result.explanation)
    assert is_map(result.evidence)
    result
  end

  defp evaluate!(root, output) do
    contract = parse!(root)
    observation = observation!(output)

    {:ok, evaluation} =
      Contracts.evaluate(contract, observation,
        evaluation_id: "evaluation-1",
        evaluated_at: @evaluated_at
      )

    evaluation
  end

  defp parse!(root) do
    {:ok, contract} =
      Contracts.parse_contract(%{
        "schema_version" => 1,
        "contract_id" => "contract-1",
        "contract_version" => 1,
        "monitor_id" => "monitor-1",
        "root" => root
      })

    contract
  end

  defp observation!(output) do
    {:ok, observation} =
      Contracts.new_observation(%{"id" => "observation-1", "output_text" => output})

    observation
  end

  defp json_valid, do: %{"id" => "valid_json", "type" => "json_valid"}
end
