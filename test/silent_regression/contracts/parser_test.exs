defmodule SilentRegression.Contracts.ParserTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Contracts.{Contract, JsonPointer, Limits, Parser}

  describe "contract schema version 1" do
    test "parses every leaf primitive and computes a stable behavior fingerprint" do
      rules = valid_leaf_rules()
      attributes = contract(%{"id" => "root", "type" => "all", "rules" => rules})

      assert {:ok, %Contract{} = parsed} = Parser.parse(attributes)
      assert parsed.schema_version == 1
      assert parsed.contract_id == "contract-1"
      assert parsed.contract_version == 1
      assert parsed.monitor_id == "monitor-1"
      assert length(parsed.root["rules"]) == length(rules)
      assert parsed.fingerprint =~ ~r/\A[0-9a-f]{64}\z/

      assert {:ok, same_behavior_new_version} =
               attributes
               |> Map.put("contract_version", 2)
               |> Parser.parse()

      assert same_behavior_new_version.fingerprint == parsed.fingerprint
      assert Contract.to_source_map(parsed) == attributes
      assert Contract.to_map(parsed)["fingerprint"] == parsed.fingerprint
    end

    test "keeps the checked-in JSON schema rule list synchronized with the parser" do
      schema =
        "docs/contracts/deterministic-contract-v1.schema.json"
        |> File.read!()
        |> Jason.decode!()

      types =
        schema["$defs"]["rule"]["oneOf"]
        |> Enum.map(fn %{"$ref" => "#/$defs/" <> definition} ->
          schema["$defs"][definition]["properties"]["type"]["const"]
        end)

      assert Enum.sort(types) == Enum.sort(Parser.rule_types())
      assert schema["properties"]["schema_version"]["const"] == 1
    end

    test "accepts explicit alert severity without changing the omitted default source" do
      source = contract(json_valid())

      assert {:ok, omitted} = Parser.parse(source)
      assert Contract.to_source_map(omitted) == source

      warning_source =
        put_in(source, ["root", "severity"], "warning")

      assert {:ok, warning} = Parser.parse(warning_source)
      assert warning.root["severity"] == "warning"
      refute warning.fingerprint == omitted.fingerprint

      invalid_source = put_in(source, ["root", "severity"], "notice")
      assert {:error, %{"code" => "unsupported_value"}} = Parser.parse(invalid_source)
    end

    test "rejects unknown fields, rule types, executable hooks, and regex input" do
      scenarios = [
        {Map.put(contract(json_valid()), "future", true), "unexpected_fields"},
        {contract(%{"id" => "future", "type" => "semantic_similarity"}), "unsupported_rule_type"},
        {contract(Map.put(json_valid(), "code", "System.cmd('sh')")), "unexpected_fields"},
        {contract(Map.put(json_valid(), "regex", "(a+)+$")), "unexpected_fields"}
      ]

      for {attributes, code} <- scenarios do
        assert {:error, %{"code" => ^code}} = Parser.parse(attributes)
      end
    end

    test "requires string keys and never accepts atom-keyed customer maps" do
      assert {:error, %{"code" => "non_string_key"}} =
               Parser.parse(%{schema_version: 1})

      source = File.read!("lib/silent_regression/contracts/parser.ex")
      refute source =~ "String.to_atom"
      refute source =~ "keys: :atoms"
    end

    test "strict JSON rejects invalid UTF-8, malformed JSON, and duplicate object keys" do
      assert {:error, %{"code" => "invalid_utf8"}} = Parser.parse_json(<<255>>)
      assert {:error, %{"code" => "invalid_json"}} = Parser.parse_json("{")

      encoded =
        ~s({"schema_version":1,"contract_id":"one","contract_id":"two","contract_version":1,"monitor_id":"m","root":{"id":"json","type":"json_valid"}})

      assert {:error, %{"code" => "duplicate_object_key"}} = Parser.parse_json(encoded)

      deeply_nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
      assert {:error, %{"code" => "json_nesting_too_deep"}} = Parser.parse_json(deeply_nested)
    end

    test "rejects malformed configuration for every leaf primitive" do
      oversized = String.duplicate("a", Limits.alternative_bytes() + 1)

      malformed_rules = [
        {Map.put(json_valid(), "extra", true), "unexpected_fields"},
        {%{"id" => "exists", "type" => "json_path_exists", "path" => "items/0"},
         "invalid_json_pointer"},
        {%{
           "id" => "typed",
           "type" => "json_path_type",
           "path" => "",
           "expected_type" => "decimal"
         }, "unsupported_value"},
        {%{
           "id" => "equal",
           "type" => "json_path_equals",
           "path" => "",
           "numeric_comparison" => "strict"
         }, "missing_fields"},
        {%{
           "id" => "allowed",
           "type" => "json_path_allowed_values",
           "path" => "",
           "allowed_values" => [],
           "numeric_comparison" => "strict"
         }, "invalid_allowed_values"},
        {%{"id" => "number", "type" => "json_path_number", "path" => "/score", "target" => 1},
         "incomplete_tolerance"},
        {%{
           "id" => "null_number",
           "type" => "json_path_number",
           "path" => "/score",
           "minimum" => nil,
           "maximum" => 1
         }, "invalid_numeric_bound"},
        {%{
           "id" => "huge_number",
           "type" => "json_path_number",
           "path" => "/score",
           "maximum" => 9_007_199_254_740_992
         }, "invalid_numeric_bound"},
        {%{
           "id" => "class",
           "type" => "classification",
           "allowed_values" => ["Needs Review", "needs-review"]
         }, "duplicate_alternative"},
        {%{"id" => "required", "type" => "required_text", "alternatives" => [" "]},
         "invalid_alternative"},
        {%{"id" => "forbidden", "type" => "forbidden_text", "alternatives" => [oversized]},
         "invalid_alternative"},
        {%{"id" => "sources", "type" => "required_source_ids", "source_ids" => ["bad source"]},
         "invalid_source_id"},
        {%{
           "id" => "source_allow",
           "type" => "allowed_source_ids",
           "source_ids" => ["doc-1"],
           "require_at_least_one" => "yes"
         }, "invalid_type"},
        {%{
           "id" => "attribution",
           "type" => "fact_citation",
           "fact_alternatives" => ["approved"],
           "source_ids" => ["policy"],
           "max_distance_characters" => 0
         }, "invalid_distance"},
        {%{"id" => "abstain", "type" => "required_abstention", "alternatives" => []},
         "invalid_alternatives"},
        {%{"id" => "length", "type" => "length", "unit" => "words"}, "missing_length_bound"}
      ]

      for {rule, code} <- malformed_rules do
        assert {:error, %{"code" => ^code}} = Parser.parse(contract(rule)), inspect(rule)
      end
    end

    test "rejects duplicate IDs, excessive depth, node count, and encoded size" do
      duplicate = %{
        "id" => "root",
        "type" => "all",
        "rules" => [json_valid("same"), json_valid("same")]
      }

      assert {:error, %{"code" => "duplicate_rule_id"}} = Parser.parse(contract(duplicate))

      too_deep =
        Enum.reduce(1..5, json_valid("leaf"), fn index, child ->
          %{"id" => "not_#{index}", "type" => "not", "rule" => child}
        end)

      assert {:error, %{"code" => "rule_depth_exceeded"}} = Parser.parse(contract(too_deep))

      too_many = %{
        "id" => "root",
        "type" => "all",
        "rules" =>
          for group <- 1..20 do
            %{
              "id" => "group_#{group}",
              "type" => "all",
              "rules" => for(item <- 1..5, do: json_valid("json_#{group}_#{item}"))
            }
          end
      }

      assert {:error, %{"code" => "rule_count_exceeded"}} = Parser.parse(contract(too_many))

      oversized =
        contract(%{
          "id" => "large",
          "type" => "required_text",
          "alternatives" => [String.duplicate("x", Limits.contract_bytes())]
        })

      assert {:error, %{"code" => "contract_too_large"}} = Parser.parse(oversized)
    end

    test "validates range and exact boundary relationships" do
      assert {:ok, _contract} =
               Parser.parse(
                 contract(%{
                   "id" => "number",
                   "type" => "json_path_number",
                   "path" => "/score",
                   "minimum" => 1,
                   "maximum" => 1,
                   "target" => 1,
                   "tolerance" => 0
                 })
               )

      assert {:error, %{"code" => "invalid_range"}} =
               Parser.parse(
                 contract(%{
                   "id" => "number",
                   "type" => "json_path_number",
                   "path" => "/score",
                   "minimum" => 2,
                   "maximum" => 1
                 })
               )

      assert {:error, %{"code" => "invalid_range"}} =
               Parser.parse(
                 contract(%{
                   "id" => "length",
                   "type" => "length",
                   "unit" => "graphemes",
                   "minimum" => 2,
                   "maximum" => 1
                 })
               )
    end
  end

  describe "RFC 6901 JSON Pointer" do
    test "decodes root, escaped object members, arrays, and empty member names" do
      document = %{"" => "empty", "a/b" => %{"m~n" => ["zero", "one"]}}

      for {pointer, expected} <- [
            {"", document},
            {"/", "empty"},
            {"/a~1b/m~0n/0", "zero"},
            {"/a~1b/m~0n/1", "one"}
          ] do
        assert {:ok, tokens} = JsonPointer.parse(pointer)
        assert {:ok, ^expected} = JsonPointer.fetch(document, tokens)
      end
    end

    test "rejects invalid escapes and non-canonical array indices" do
      assert {:error, :invalid_escape} = JsonPointer.parse("/bad~2escape")
      assert {:ok, ["01"] = tokens} = JsonPointer.parse("/01")
      assert {:error, :invalid_array_index} = JsonPointer.fetch(["zero", "one"], tokens)
      assert {:ok, ["-"] = tokens} = JsonPointer.parse("/-")
      assert {:error, :invalid_array_index} = JsonPointer.fetch([], tokens)
    end
  end

  defp contract(root) do
    %{
      "schema_version" => 1,
      "contract_id" => "contract-1",
      "contract_version" => 1,
      "monitor_id" => "monitor-1",
      "root" => root
    }
  end

  defp json_valid(id \\ "valid_json"), do: %{"id" => id, "type" => "json_valid"}

  defp valid_leaf_rules do
    [
      json_valid(),
      %{"id" => "exists", "type" => "json_path_exists", "path" => "/items/0"},
      %{
        "id" => "typed",
        "type" => "json_path_type",
        "path" => "/items",
        "expected_type" => "array"
      },
      %{
        "id" => "equal",
        "type" => "json_path_equals",
        "path" => "/state",
        "expected" => "ready",
        "numeric_comparison" => "strict"
      },
      %{
        "id" => "allowed",
        "type" => "json_path_allowed_values",
        "path" => "/state",
        "allowed_values" => ["ready", "paused"],
        "numeric_comparison" => "strict"
      },
      %{
        "id" => "number",
        "type" => "json_path_number",
        "path" => "/score",
        "minimum" => 0,
        "maximum" => 1
      },
      %{"id" => "class", "type" => "classification", "allowed_values" => ["approve", "reject"]},
      %{"id" => "required", "type" => "required_text", "alternatives" => ["approved"]},
      %{"id" => "forbidden", "type" => "forbidden_text", "alternatives" => ["unverified"]},
      %{"id" => "sources", "type" => "required_source_ids", "source_ids" => ["policy-1"]},
      %{
        "id" => "source_allow",
        "type" => "allowed_source_ids",
        "source_ids" => ["policy-1"],
        "require_at_least_one" => true
      },
      %{
        "id" => "attribution",
        "type" => "fact_citation",
        "fact_alternatives" => ["approved"],
        "source_ids" => ["policy-1"],
        "max_distance_characters" => 120
      },
      %{"id" => "abstain", "type" => "required_abstention", "alternatives" => ["not specified"]},
      %{"id" => "length", "type" => "length", "unit" => "words", "minimum" => 1, "maximum" => 100}
    ]
  end
end
