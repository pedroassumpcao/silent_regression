defmodule SilentRegression.Contracts.Evaluator do
  @moduledoc false

  alias SilentRegression.Contracts.{
    Citations,
    Evidence,
    JsonPointer,
    RuleResult,
    StrictJson,
    Text
  }

  @spec evaluate(map(), String.t()) :: {:pass | :fail | :evaluator_error, [RuleResult.t()]}
  def evaluate(root, output) do
    context = %{
      output: output,
      normalized_output: Text.normalize(output),
      json: StrictJson.decode(output),
      citations: Citations.extract(output)
    }

    evaluate_rule(root, context)
  end

  defp evaluate_rule(rule, context) do
    do_evaluate_rule(rule, context)
  rescue
    exception ->
      rule_id = if is_map(rule), do: Map.get(rule, "id", "unknown"), else: "unknown"
      rule_type = if is_map(rule), do: Map.get(rule, "type", "unknown"), else: "unknown"

      result =
        result(
          rule_id,
          rule_type,
          :evaluator_error,
          "unexpected_evaluator_error",
          "The evaluator could not safely determine this rule's outcome.",
          %{
            "exception_type" =>
              exception |> Map.fetch!(:__struct__) |> Module.split() |> List.last()
          }
        )

      {:evaluator_error, [result]}
  end

  defp do_evaluate_rule(%{"type" => type, "rules" => rules} = rule, context)
       when type in ["all", "any"] do
    children = Enum.map(rules, &evaluate_rule(&1, context))
    child_statuses = Enum.map(children, &elem(&1, 0))
    status = composite_status(type, child_statuses)
    child_ids = Enum.map(rules, & &1["id"])

    {code, explanation} = composite_message(type, status)

    parent =
      result(
        rule["id"],
        type,
        status,
        code,
        explanation,
        %{
          "passed_children" => Enum.count(child_statuses, &(&1 == :pass)),
          "failed_children" => Enum.count(child_statuses, &(&1 == :fail)),
          "error_children" => Enum.count(child_statuses, &(&1 == :evaluator_error))
        },
        child_ids,
        severity(rule)
      )

    {status, [parent | Enum.flat_map(children, &elem(&1, 1))]}
  end

  defp do_evaluate_rule(%{"type" => "not", "rule" => child} = rule, context) do
    {child_status, child_results} = evaluate_rule(child, context)

    status =
      case child_status do
        :pass -> :fail
        :fail -> :pass
        :evaluator_error -> :evaluator_error
      end

    {code, explanation} =
      case status do
        :pass ->
          {"negated_rule_failed", "The negated child rule failed as required."}

        :fail ->
          {"negated_rule_passed", "The negated child rule passed, so this rule failed."}

        :evaluator_error ->
          {"child_evaluator_error", "The negated child rule could not be evaluated safely."}
      end

    parent =
      result(
        rule["id"],
        "not",
        status,
        code,
        explanation,
        %{},
        [child["id"]],
        severity(rule)
      )

    {status, [parent | child_results]}
  end

  defp do_evaluate_rule(%{"type" => "json_valid"} = rule, context) do
    case context.json do
      {:ok, actual} ->
        leaf(
          rule,
          :pass,
          "valid_json",
          "The output is valid JSON with unique object keys.",
          %{"root_type" => Evidence.json_type(actual)}
        )

      {:error, :nesting_too_deep} ->
        leaf(
          rule,
          :evaluator_error,
          "json_nesting_too_deep",
          "The output exceeds the evaluator's safe JSON nesting limit."
        )

      {:error, reason} ->
        leaf(
          rule,
          :fail,
          Atom.to_string(reason),
          json_decode_explanation(reason)
        )
    end
  end

  defp do_evaluate_rule(%{"type" => "json_path_exists"} = rule, context) do
    case fetch_json_value(rule, context) do
      {:ok, actual} ->
        leaf(
          rule,
          :pass,
          "json_path_present",
          "The required JSON Pointer resolves.",
          path_evidence(rule, actual)
        )

      {:error, reason} ->
        json_lookup_failure(rule, reason)
    end
  end

  defp do_evaluate_rule(%{"type" => "json_path_type"} = rule, context) do
    case fetch_json_value(rule, context) do
      {:ok, actual} ->
        actual_type = Evidence.json_type(actual)
        expected_type = rule["expected_type"]
        passed = type_matches?(actual, expected_type)

        if passed do
          leaf(rule, :pass, "json_type_matched", "The JSON value has the required type.", %{
            "path" => Evidence.text(rule["path"]),
            "expected_type" => expected_type,
            "actual_type" => actual_type
          })
        else
          leaf(rule, :fail, "json_type_mismatch", "The JSON value has a different type.", %{
            "path" => Evidence.text(rule["path"]),
            "expected_type" => expected_type,
            "actual_type" => actual_type
          })
        end

      {:error, reason} ->
        json_lookup_failure(rule, reason)
    end
  end

  defp do_evaluate_rule(%{"type" => "json_path_equals"} = rule, context) do
    case fetch_json_value(rule, context) do
      {:ok, actual} ->
        expected = rule["expected"]
        evidence = equality_evidence(rule, expected, actual)

        if json_equal?(actual, expected, rule["numeric_comparison"]) do
          leaf(
            rule,
            :pass,
            "json_value_matched",
            "The JSON value matches the configured value.",
            evidence
          )
        else
          leaf(
            rule,
            :fail,
            "json_value_mismatch",
            "The JSON value does not match the configured value.",
            evidence
          )
        end

      {:error, reason} ->
        json_lookup_failure(rule, reason)
    end
  end

  defp do_evaluate_rule(%{"type" => "json_path_allowed_values"} = rule, context) do
    case fetch_json_value(rule, context) do
      {:ok, actual} ->
        matched_index =
          Enum.find_index(
            rule["allowed_values"],
            &json_equal?(actual, &1, rule["numeric_comparison"])
          )

        matched =
          if is_nil(matched_index), do: nil, else: Enum.at(rule["allowed_values"], matched_index)

        evidence = %{
          "path" => Evidence.text(rule["path"]),
          "actual" => Evidence.value(actual),
          "allowed_value_count" => length(rule["allowed_values"]),
          "matched_value" => if(is_nil(matched_index), do: nil, else: Evidence.value(matched)),
          "numeric_comparison" => rule["numeric_comparison"]
        }

        if is_nil(matched_index) do
          leaf(
            rule,
            :fail,
            "json_value_not_allowed",
            "The JSON value is outside the configured allowed set.",
            evidence
          )
        else
          leaf(
            rule,
            :pass,
            "json_value_allowed",
            "The JSON value is in the configured allowed set.",
            evidence
          )
        end

      {:error, reason} ->
        json_lookup_failure(rule, reason)
    end
  end

  defp do_evaluate_rule(%{"type" => "json_path_number"} = rule, context) do
    case fetch_json_value(rule, context) do
      {:ok, actual} when is_number(actual) ->
        violations = numeric_violations(actual, rule)

        evidence = %{
          "path" => Evidence.text(rule["path"]),
          "actual" => actual,
          "minimum" => Map.get(rule, "minimum"),
          "maximum" => Map.get(rule, "maximum"),
          "target" => Map.get(rule, "target"),
          "tolerance" => Map.get(rule, "tolerance"),
          "violations" => violations
        }

        if violations == [] do
          leaf(
            rule,
            :pass,
            "json_number_within_bounds",
            "The JSON number is within every configured bound.",
            evidence
          )
        else
          leaf(
            rule,
            :fail,
            "json_number_out_of_bounds",
            "The JSON number is outside a configured bound.",
            evidence
          )
        end

      {:ok, actual} ->
        leaf(rule, :fail, "json_type_mismatch", "The JSON value is not a number.", %{
          "path" => Evidence.text(rule["path"]),
          "actual_type" => Evidence.json_type(actual)
        })

      {:error, reason} ->
        json_lookup_failure(rule, reason)
    end
  end

  defp do_evaluate_rule(%{"type" => "classification"} = rule, context) do
    matched =
      Enum.find(rule["allowed_values"], &(Text.normalize(&1) == context.normalized_output))

    evidence = %{
      "normalized_output" => Evidence.text(context.normalized_output),
      "allowed_value_count" => length(rule["allowed_values"]),
      "matched_value" => matched
    }

    if is_nil(matched) do
      leaf(
        rule,
        :fail,
        "classification_not_allowed",
        "The normalized output is not an allowed classification label.",
        evidence
      )
    else
      leaf(
        rule,
        :pass,
        "classification_allowed",
        "The normalized output matches an allowed classification label.",
        evidence
      )
    end
  end

  defp do_evaluate_rule(%{"type" => "required_text"} = rule, context) do
    matched =
      Enum.find(
        rule["alternatives"],
        &Text.contains_normalized_literal?(context.normalized_output, &1)
      )

    if matched do
      leaf(
        rule,
        :pass,
        "required_text_present",
        "A configured required-text alternative is present.",
        %{
          "matched_alternative" => Evidence.text(matched)
        }
      )
    else
      leaf(
        rule,
        :fail,
        "required_text_missing",
        "No configured required-text alternative is present.",
        %{
          "alternative_count" => length(rule["alternatives"])
        }
      )
    end
  end

  defp do_evaluate_rule(%{"type" => "forbidden_text"} = rule, context) do
    matched =
      Enum.find(
        rule["alternatives"],
        &Text.contains_normalized_literal?(context.normalized_output, &1)
      )

    if matched do
      leaf(
        rule,
        :fail,
        "forbidden_text_present",
        "A configured forbidden-text alternative is present.",
        %{
          "matched_alternative" => Evidence.text(matched)
        }
      )
    else
      leaf(
        rule,
        :pass,
        "forbidden_text_absent",
        "No configured forbidden-text alternative is present.",
        %{
          "alternative_count" => length(rule["alternatives"])
        }
      )
    end
  end

  defp do_evaluate_rule(%{"type" => "required_source_ids"} = rule, context) do
    found = Citations.ids(context.citations)
    missing = Enum.reject(rule["source_ids"], &(&1 in found))

    evidence = %{
      "required_source_ids" => Evidence.list(rule["source_ids"]),
      "missing_source_ids" => Evidence.list(missing)
    }

    if missing == [] do
      leaf(
        rule,
        :pass,
        "required_source_ids_present",
        "Every required source ID is cited.",
        evidence
      )
    else
      leaf(
        rule,
        :fail,
        "required_source_ids_missing",
        "One or more required source IDs are not cited.",
        evidence
      )
    end
  end

  defp do_evaluate_rule(%{"type" => "allowed_source_ids"} = rule, context) do
    found = Citations.ids(context.citations)
    disallowed = Enum.reject(found, &(&1 in rule["source_ids"]))

    evidence = %{
      "found_source_ids" => Evidence.list(found),
      "disallowed_source_ids" => Evidence.list(disallowed),
      "require_at_least_one" => rule["require_at_least_one"]
    }

    cond do
      disallowed != [] ->
        leaf(
          rule,
          :fail,
          "disallowed_source_id_present",
          "A citation uses a source ID outside the configured set.",
          evidence
        )

      rule["require_at_least_one"] and found == [] ->
        leaf(
          rule,
          :fail,
          "source_id_missing",
          "At least one configured source citation is required.",
          evidence
        )

      true ->
        leaf(
          rule,
          :pass,
          "source_ids_allowed",
          "Every detected source citation is allowed.",
          evidence
        )
    end
  end

  defp do_evaluate_rule(%{"type" => "fact_citation"} = rule, context) do
    matched_fact =
      Enum.find(
        rule["fact_alternatives"],
        &Text.contains_normalized_literal?(context.normalized_output, &1)
      )

    evidence = %{
      "matched_fact" => if(is_nil(matched_fact), do: nil, else: Evidence.text(matched_fact)),
      "found_source_ids" => Evidence.list(Citations.ids(context.citations)),
      "allowed_source_ids" => Evidence.list(rule["source_ids"]),
      "max_distance_characters" => rule["max_distance_characters"]
    }

    cond do
      is_nil(matched_fact) ->
        leaf(
          rule,
          :fail,
          "cited_fact_missing",
          "No configured fact alternative is present.",
          evidence
        )

      true ->
        case Citations.attributed_match(
               context.output,
               context.citations,
               rule["fact_alternatives"],
               rule["source_ids"],
               rule["max_distance_characters"]
             ) do
          {:ok, match} ->
            leaf(
              rule,
              :pass,
              "fact_citation_matched",
              "A configured fact has a bounded trailing source citation.",
              Map.put(evidence, "match", match)
            )

          :error ->
            leaf(
              rule,
              :fail,
              "fact_citation_missing",
              "The configured fact lacks an allowed bounded trailing citation.",
              evidence
            )
        end
    end
  end

  defp do_evaluate_rule(%{"type" => "required_abstention"} = rule, context) do
    matched =
      Enum.find(
        rule["alternatives"],
        &Text.contains_normalized_literal?(context.normalized_output, &1)
      )

    if matched do
      leaf(
        rule,
        :pass,
        "abstention_present",
        "A customer-approved abstention alternative is present.",
        %{
          "matched_alternative" => Evidence.text(matched)
        }
      )
    else
      leaf(
        rule,
        :fail,
        "abstention_missing",
        "No customer-approved abstention alternative is present.",
        %{
          "alternative_count" => length(rule["alternatives"])
        }
      )
    end
  end

  defp do_evaluate_rule(%{"type" => "length"} = rule, context) do
    actual =
      case rule["unit"] do
        "graphemes" -> String.length(context.output)
        "words" -> Text.word_count(context.output)
      end

    violations =
      []
      |> maybe_violation(
        Map.has_key?(rule, "minimum") and actual < rule["minimum"],
        "below_minimum"
      )
      |> maybe_violation(
        Map.has_key?(rule, "maximum") and actual > rule["maximum"],
        "above_maximum"
      )

    evidence = %{
      "unit" => rule["unit"],
      "actual" => actual,
      "minimum" => Map.get(rule, "minimum"),
      "maximum" => Map.get(rule, "maximum"),
      "violations" => violations
    }

    if violations == [] do
      leaf(
        rule,
        :pass,
        "length_within_bounds",
        "The output length is within the configured bounds.",
        evidence
      )
    else
      leaf(
        rule,
        :fail,
        "length_out_of_bounds",
        "The output length is outside a configured bound.",
        evidence
      )
    end
  end

  defp do_evaluate_rule(rule, _context) do
    leaf(
      rule,
      :evaluator_error,
      "unsupported_internal_rule",
      "The evaluator received a rule that was not validated for this engine version."
    )
  end

  defp composite_status(type, statuses) do
    cond do
      :evaluator_error in statuses -> :evaluator_error
      type == "all" and Enum.all?(statuses, &(&1 == :pass)) -> :pass
      type == "any" and Enum.any?(statuses, &(&1 == :pass)) -> :pass
      true -> :fail
    end
  end

  defp composite_message("all", :pass),
    do: {"all_children_passed", "Every child rule passed."}

  defp composite_message("all", :fail),
    do: {"all_child_failed", "At least one child rule failed."}

  defp composite_message("any", :pass),
    do: {"any_child_passed", "At least one child rule passed."}

  defp composite_message("any", :fail),
    do: {"no_child_passed", "No child rule passed."}

  defp composite_message(_type, :evaluator_error),
    do: {"child_evaluator_error", "At least one child rule could not be evaluated safely."}

  defp fetch_json_value(rule, context) do
    with {:ok, document} <- wrap_json_result(context.json),
         {:ok, tokens} <- wrap_pointer_result(JsonPointer.parse(rule["path"])),
         {:ok, value} <- wrap_lookup_result(JsonPointer.fetch(document, tokens)) do
      {:ok, value}
    end
  end

  defp wrap_json_result({:ok, document}), do: {:ok, document}
  defp wrap_json_result({:error, reason}), do: {:error, {:json, reason}}
  defp wrap_pointer_result({:ok, tokens}), do: {:ok, tokens}
  defp wrap_pointer_result({:error, reason}), do: {:error, {:pointer, reason}}
  defp wrap_lookup_result({:ok, value}), do: {:ok, value}
  defp wrap_lookup_result({:error, reason}), do: {:error, {:lookup, reason}}

  defp json_lookup_failure(rule, {:json, :nesting_too_deep}) do
    leaf(
      rule,
      :evaluator_error,
      "json_nesting_too_deep",
      "The output exceeds the evaluator's safe JSON nesting limit.",
      %{"path" => Evidence.text(rule["path"])}
    )
  end

  defp json_lookup_failure(rule, {:json, reason}) do
    leaf(rule, :fail, Atom.to_string(reason), json_decode_explanation(reason), %{
      "path" => Evidence.text(rule["path"])
    })
  end

  defp json_lookup_failure(rule, {:lookup, reason}) do
    {code, explanation} =
      case reason do
        :missing ->
          {"json_path_missing", "The required JSON Pointer does not resolve."}

        :invalid_array_index ->
          {"json_path_invalid_array_index",
           "The JSON Pointer token is not a canonical array index."}

        :wrong_container_type ->
          {"json_path_wrong_container", "The JSON Pointer traverses a scalar value."}
      end

    leaf(rule, :fail, code, explanation, %{"path" => Evidence.text(rule["path"])})
  end

  defp json_lookup_failure(rule, {:pointer, _reason}) do
    leaf(
      rule,
      :evaluator_error,
      "invalid_internal_json_pointer",
      "The validated contract contains an unusable JSON Pointer."
    )
  end

  defp json_decode_explanation(:invalid_json), do: "The output is not valid raw JSON."

  defp json_decode_explanation(:duplicate_object_key),
    do: "The output contains a duplicate JSON object key."

  defp json_decode_explanation(:invalid_utf8), do: "The output is not valid UTF-8."

  defp path_evidence(rule, actual) do
    %{"path" => Evidence.text(rule["path"]), "actual" => Evidence.value(actual)}
  end

  defp equality_evidence(rule, expected, actual) do
    %{
      "path" => Evidence.text(rule["path"]),
      "expected" => Evidence.value(expected),
      "actual" => Evidence.value(actual),
      "numeric_comparison" => rule["numeric_comparison"]
    }
  end

  defp type_matches?(value, "object"), do: is_map(value)
  defp type_matches?(value, "array"), do: is_list(value)
  defp type_matches?(value, "string"), do: is_binary(value)
  defp type_matches?(value, "number"), do: is_number(value)
  defp type_matches?(value, "integer"), do: is_integer(value)
  defp type_matches?(value, "boolean"), do: is_boolean(value)
  defp type_matches?(value, "null"), do: is_nil(value)

  defp json_equal?(actual, expected, "strict"), do: actual === expected

  defp json_equal?(actual, expected, "mathematical")
       when is_number(actual) and is_number(expected),
       do: actual == expected

  defp json_equal?(actual, expected, "mathematical")
       when is_map(actual) and is_map(expected) do
    Map.keys(actual) |> Enum.sort() == Map.keys(expected) |> Enum.sort() and
      Enum.all?(expected, fn {key, value} ->
        Map.has_key?(actual, key) and json_equal?(actual[key], value, "mathematical")
      end)
  end

  defp json_equal?(actual, expected, "mathematical")
       when is_list(actual) and is_list(expected) do
    length(actual) == length(expected) and
      actual
      |> Enum.zip(expected)
      |> Enum.all?(fn {actual, expected} -> json_equal?(actual, expected, "mathematical") end)
  end

  defp json_equal?(actual, expected, "mathematical"), do: actual === expected

  defp numeric_violations(actual, rule) do
    []
    |> maybe_violation(
      Map.has_key?(rule, "minimum") and actual < rule["minimum"],
      "below_minimum"
    )
    |> maybe_violation(
      Map.has_key?(rule, "maximum") and actual > rule["maximum"],
      "above_maximum"
    )
    |> maybe_violation(
      Map.has_key?(rule, "target") and
        (actual < rule["target"] - rule["tolerance"] or
           actual > rule["target"] + rule["tolerance"]),
      "outside_tolerance"
    )
  end

  defp maybe_violation(violations, true, violation), do: violations ++ [violation]
  defp maybe_violation(violations, false, _violation), do: violations

  defp leaf(rule, status, code, explanation, evidence \\ %{}) do
    result =
      result(rule["id"], rule["type"], status, code, explanation, evidence, [], severity(rule))

    {status, [result]}
  end

  defp result(
         rule_id,
         rule_type,
         status,
         code,
         explanation,
         evidence,
         child_ids \\ [],
         severity \\ :critical
       ) do
    %RuleResult{
      rule_id: rule_id,
      rule_type: rule_type,
      severity: severity,
      status: status,
      code: code,
      explanation: explanation,
      evidence: evidence,
      child_rule_ids: child_ids
    }
  end

  defp severity(%{"severity" => "warning"}), do: :warning
  defp severity(_rule), do: :critical
end
