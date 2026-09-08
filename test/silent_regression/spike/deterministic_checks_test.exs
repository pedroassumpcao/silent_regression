defmodule SilentRegression.Spike.DeterministicChecksTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.DeterministicChecks

  describe "the approved RAG suite" do
    test "passes the structured extraction reference output" do
      case_definition = fetch_case!("rag_structured_extract")

      output =
        Jason.encode!(%{
          "project_name" => "Meridian Lantern",
          "launch_date" => "2042-11-18",
          "city" => "Bellweather Harbor",
          "budget_usd" => 480_000,
          "source_ids" => ["brief-7", "finance-2"]
        })

      assert %{"all_passed" => true, "pass_rate" => 1.0} = evaluate!(case_definition, output)
    end

    test "passes a grounded answer with all required citations" do
      case_definition = fetch_case!("rag_answer_with_citations")

      output =
        "Guided tours run Wednesdays and Fridays at 10:30 a.m. and last 75 minutes " <>
          "[tour-schedule]. Book at least 24 hours ahead [booking-policy]."

      assert %{"all_passed" => true, "passed_checks" => 5} =
               evaluate!(case_definition, output)
    end

    test "passes a supported abstention without an invented answer" do
      case_definition = fetch_case!("rag_abstain_when_unsupported")

      output =
        "The benefits guide does not specify the amount of paid parental leave " <>
          "[benefits-guide]."

      assert %{"all_passed" => true, "pass_rate" => 1.0} = evaluate!(case_definition, output)
    end

    test "passes a valid open synthesis while retaining per-fact diagnostics" do
      case_definition = fetch_case!("rag_open_synthesis")

      output = """
      The full fleet is 12 electric ferries, but phase one funds only the first six
      ferries. The target is a 19-minute crossing by 2044 [transit-plan]
      [phase-one-budget].

      From March through July, the route near the islands is limited to 12 knots,
      creating a habitat protection tradeoff [habitat-rules].
      """

      result = evaluate!(case_definition, output)

      assert result["all_passed"]
      assert result["passed_checks"] == 6
      assert Enum.all?(result["checks"], &is_binary(&1["reason"]))
    end
  end

  describe "JSON object checks" do
    test "accepts bare and singly fenced JSON objects" do
      case_definition = case_with_checks([json_check(%{"label" => "safe", "count" => 2})])

      for output <- [
            ~s({"label":"safe","count":2}),
            """
            ```json
            {"label":"safe","count":2}
            ```
            """,
            """
            ```
            {"label":"safe","count":2}
            ```
            """
          ] do
        assert %{"all_passed" => true} = evaluate!(case_definition, output)
      end
    end

    test "rejects prose-wrapped JSON and non-object JSON" do
      case_definition = case_with_checks([json_check(%{"label" => "safe"})])

      scenarios = [
        {"prose prefix", ~s(Result: {"label":"safe"}), "invalid_json"},
        {"prose around fence", "Result:\n```json\n{\"label\":\"safe\"}\n```", "invalid_json"},
        {"array", ~s([{"label":"safe"}]), "json_not_object"},
        {"wrong fence language", "```javascript\n{\"label\":\"safe\"}\n```", "invalid_json_fence"}
      ]

      for {name, output, expected_reason} <- scenarios do
        assert %{"checks" => [%{"passed" => false, "reason" => ^expected_reason}]} =
                 evaluate!(case_definition, output),
               name
      end
    end

    test "reports wrong values plus extra and missing keys by path" do
      case_definition = case_with_checks([json_check(%{"label" => "safe", "count" => 2})])

      scenarios = [
        {"wrong value", ~s({"label":"unsafe","count":2}), "$.label", "value_mismatch"},
        {"extra key", ~s({"label":"safe","count":2,"note":"extra"}), "$.note", "extra_key"},
        {"missing key", ~s({"label":"safe"}), "$.count", "missing_key"}
      ]

      for {name, output, expected_path, expected_reason} <- scenarios do
        result = evaluate!(case_definition, output)
        [check_result] = result["checks"]

        assert check_result["reason"] == "json_mismatch", name

        assert Enum.any?(check_result["details"]["mismatches"], fn mismatch ->
                 mismatch["path"] == expected_path and mismatch["reason"] == expected_reason
               end),
               name
      end
    end

    test "allows recursive extra keys only when configured" do
      expected = %{"outer" => %{"required" => true}}
      output = ~s({"outer":{"required":true,"extra":"ok"},"top_extra":1})

      strict_case = case_with_checks([json_check(expected)])
      subset_case = case_with_checks([json_check(expected, allow_extra_keys: true)])

      refute evaluate!(strict_case, output)["all_passed"]
      assert evaluate!(subset_case, output)["all_passed"]
    end

    test "documents mathematical and strict numeric representation" do
      output = ~s({"budget":480000.0})

      mathematical_case =
        case_with_checks([json_check(%{"budget" => 480_000}, numeric_comparison: "mathematical")])

      strict_case =
        case_with_checks([json_check(%{"budget" => 480_000}, numeric_comparison: "strict")])

      assert evaluate!(mathematical_case, output)["all_passed"]
      refute evaluate!(strict_case, output)["all_passed"]
    end

    test "keeps array ordering deterministic" do
      case_definition = case_with_checks([json_check(%{"sources" => ["one", "two"]})])

      assert evaluate!(case_definition, ~s({"sources":["one","two"]}))["all_passed"]
      refute evaluate!(case_definition, ~s({"sources":["two","one"]}))["all_passed"]
    end
  end

  describe "normalized facts and labels" do
    test "normalizes Unicode, punctuation, case, and whitespace" do
      assert DeterministicChecks.normalize_fact("  Café—SIX\tWeeks!  ") == "café six weeks"
      assert DeterministicChecks.normalize_fact("ＡＢＣ") == "abc"
      assert DeterministicChecks.normalize_fact("Straße") == "strasse"
    end

    test "matches required facts as complete normalized token sequences" do
      case_definition =
        case_with_checks([
          %{
            "type" => "required_fact",
            "id" => "duration",
            "any_of" => ["75-minute", "seventy-five minutes"]
          }
        ])

      assert evaluate!(case_definition, "The tour is a 75 MINUTE experience.")["all_passed"]
      refute evaluate!(case_definition, "The tour is a 175-minute experience.")["all_passed"]
    end

    test "matches grouped fact alternatives within a bounded token span" do
      case_definition =
        case_with_checks([
          %{
            "type" => "required_fact_groups",
            "id" => "phase_one_fleet",
            "groups" => [
              ["phase one", "first phase"],
              ["six ferries", "6 ferries"]
            ],
            "max_span_tokens" => 12
          }
        ])

      matching =
        evaluate!(
          case_definition,
          "The funded first phase covers the terminal conversion and six ferries."
        )

      assert matching["all_passed"]
      assert hd(matching["checks"])["reason"] == "all_fact_groups_matched"

      missing = evaluate!(case_definition, "Phase one funds only the terminal conversion.")
      refute missing["all_passed"]
      assert hd(missing["checks"])["reason"] == "required_fact_groups_missing"

      distant =
        evaluate!(
          case_definition,
          "Phase one " <> String.duplicate("unrelated ", 20) <> "covers six ferries."
        )

      refute distant["all_passed"]
      assert hd(distant["checks"])["reason"] == "required_fact_groups_too_distant"
    end

    test "supports exact normalized labels without substring matching" do
      case_definition =
        case_with_checks([%{"type" => "normalized_equals", "expected" => "Needs Review"}])

      assert evaluate!(case_definition, " NEEDS—REVIEW ")["all_passed"]
      refute evaluate!(case_definition, "Needs Review Soon")["all_passed"]
    end

    test "flags forbidden normalized facts without partial-token matches" do
      case_definition =
        case_with_checks([
          %{"type" => "forbidden_fact", "id" => "invented_duration", "any_of" => ["six weeks"]}
        ])

      refute evaluate!(case_definition, "The policy provides six weeks.")["all_passed"]
      assert evaluate!(case_definition, "The policy provides sixteen weeks.")["all_passed"]
    end
  end

  describe "citations and abstention" do
    test "requires every exact bracketed source ID" do
      case_definition =
        case_with_checks([
          %{"type" => "required_source_ids", "source_ids" => ["source-a", "source-b"]}
        ])

      assert evaluate!(case_definition, "Claim [source-a]. Detail [source-b].")["all_passed"]

      for output <- [
            "Claim [source-a]. Detail [source-c].",
            "Claim [source-a]. Detail source-b.",
            "Claim [SOURCE-A]. Detail [source-b]."
          ] do
        result = evaluate!(case_definition, output)
        refute result["all_passed"]
        assert hd(result["checks"])["reason"] == "source_ids_missing"
      end
    end

    test "accepts abstention language when no unsupported answer is present" do
      case_definition = case_with_checks([abstention_check()])

      result = evaluate!(case_definition, "The number of weeks is not specified in the context.")

      assert result["all_passed"]
      assert hd(result["checks"])["reason"] == "abstention_confirmed"
    end

    test "rejects an unsupported claim even when abstention language is also present" do
      case_definition = case_with_checks([abstention_check()])

      result =
        evaluate!(
          case_definition,
          "It is not specified in the context, but employees probably receive 12 weeks."
        )

      refute result["all_passed"]
      assert hd(result["checks"])["reason"] == "forbidden_claim_present"
      assert hd(result["checks"])["details"]["matched_forbidden_patterns"] != []
    end

    test "rejects a non-answer that does not explicitly abstain" do
      case_definition = case_with_checks([abstention_check()])
      result = evaluate!(case_definition, "Paid parental leave is an employee benefit.")

      refute result["all_passed"]
      assert hd(result["checks"])["reason"] == "abstention_missing"
    end
  end

  describe "aggregation and contract failures" do
    test "returns numerator, denominator, rate, and every per-check explanation" do
      case_definition =
        case_with_checks([
          %{"type" => "required_fact", "id" => "day", "any_of" => ["Wednesday"]},
          %{"type" => "required_fact", "id" => "time", "any_of" => ["10:30"]},
          %{"type" => "required_source_ids", "source_ids" => ["schedule"]}
        ])

      result = evaluate!(case_definition, "Tours run Wednesday at 10:30.")

      assert result["status"] == "evaluated"
      assert result["passed_checks"] == 2
      assert result["total_checks"] == 3
      assert_in_delta result["pass_rate"], 2 / 3, 1.0e-12
      refute result["all_passed"]
      assert length(result["checks"]) == 3
      assert Enum.all?(result["checks"], &Map.has_key?(&1, "reason"))
      assert is_binary(Jason.encode!(result))
    end

    test "marks a case with no checks as not applicable" do
      result = case_with_checks([]) |> evaluate!("Any output")

      assert %{
               "status" => "not_applicable",
               "pass_rate" => nil,
               "all_passed" => nil,
               "checks" => []
             } = result
    end

    test "empty text fails every relevant check with an explicit reason" do
      case_definition =
        case_with_checks([
          json_check(%{"answer" => "known"}),
          %{"type" => "required_fact", "id" => "answer", "any_of" => ["known"]},
          %{"type" => "required_source_ids", "source_ids" => ["source"]},
          abstention_check()
        ])

      result = evaluate!(case_definition, "  \n\t")

      assert result["pass_rate"] == 0.0
      assert Enum.all?(result["checks"], &(&1["reason"] == "empty_output"))
    end

    test "returns structured failures for malformed and unsupported checks" do
      case_definition =
        case_with_checks([
          %{"type" => "json_equals"},
          %{"type" => "future_check", "value" => true}
        ])

      result = evaluate!(case_definition, "content")

      assert Enum.map(result["checks"], & &1["reason"]) == [
               "malformed_check",
               "unsupported_check_type"
             ]
    end

    test "rejects non-string output and non-case input" do
      case_definition = case_with_checks([])

      assert {:error, %{type: :invalid_output, reason: :must_be_a_string}} =
               DeterministicChecks.evaluate(case_definition, nil)

      assert {:error, %{type: :invalid_case, reason: :must_be_a_case_struct}} =
               DeterministicChecks.evaluate(%{}, "output")

      assert {:error, %{type: :invalid_output, reason: :must_be_valid_utf8}} =
               DeterministicChecks.evaluate(case_definition, <<255>>)
    end

    test "case-set validation recognizes the composable normalized check types" do
      case_definition =
        case_with_checks([
          %{"type" => "normalized_equals", "expected" => "approved"},
          %{"type" => "forbidden_fact", "id" => "rejected", "any_of" => ["rejected"]},
          %{
            "type" => "required_fact_groups",
            "id" => "funded_fleet",
            "groups" => [["phase one"], ["six ferries"]],
            "max_span_tokens" => 12
          }
        ])

      fingerprint = CaseSet.fingerprint(case_definition)

      assert :ok = CaseSet.validate([%{case_definition | fingerprint: fingerprint}])
    end
  end

  defp fetch_case!(id) do
    {:ok, case_definition} = CaseSet.fetch(id)
    case_definition
  end

  defp case_with_checks(checks) do
    SilentRegression.SpikeFixtures.case_definition(%{checks: checks, fingerprint: nil})
  end

  defp json_check(expected, options \\ []) do
    %{
      "type" => "json_equals",
      "expected" => expected,
      "allow_extra_keys" => Keyword.get(options, :allow_extra_keys, false),
      "numeric_comparison" => Keyword.get(options, :numeric_comparison, "mathematical")
    }
  end

  defp abstention_check do
    %{
      "type" => "abstains",
      "accepted_phrases" => ["not specified", "cannot be determined"],
      "forbidden_patterns" => ["\\b\\d+\\s+weeks?\\b"]
    }
  end

  defp evaluate!(case_definition, output_text) do
    {:ok, result} = DeterministicChecks.evaluate(case_definition, output_text)
    result
  end
end
