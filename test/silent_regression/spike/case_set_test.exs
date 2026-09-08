defmodule SilentRegression.Spike.CaseSetTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.CaseSet

  test "contains the four versioned RAG cases in stable order" do
    cases = CaseSet.all()

    assert Enum.map(cases, & &1.id) == [
             "rag_structured_extract",
             "rag_answer_with_citations",
             "rag_abstain_when_unsupported",
             "rag_open_synthesis"
           ]

    assert Map.new(cases, &{&1.id, &1.version}) == %{
             "rag_abstain_when_unsupported" => 1,
             "rag_answer_with_citations" => 1,
             "rag_open_synthesis" => 3,
             "rag_structured_extract" => 2
           }

    assert Enum.all?(cases, &(&1.fingerprint =~ ~r/\A[0-9a-f]{64}\z/))
    assert :ok = CaseSet.validate(cases)
  end

  test "fetches a case by stable ID without creating atoms" do
    assert {:ok, %Case{id: "rag_open_synthesis"}} = CaseSet.fetch("rag_open_synthesis")
    assert :error = CaseSet.fetch("missing")
    assert :error = CaseSet.fetch(:rag_open_synthesis)
  end

  test "fingerprints are stable known values" do
    fingerprints = Map.new(CaseSet.all(), &{&1.id, &1.fingerprint})

    assert fingerprints == %{
             "rag_abstain_when_unsupported" =>
               "f5c94722af012d6495ca0c41ffe0a8f2b8f8a248b9c57df6e5876ee38e4bb635",
             "rag_answer_with_citations" =>
               "3f81ddbd3e6a5ce49ea7df8a43ac28634e2e4724c86272fc7c6cb8e0c380e24f",
             "rag_open_synthesis" =>
               "f0798b6b773ccc3038b4da6b214de5706495c73ed995514298d3bd143199584a",
             "rag_structured_extract" =>
               "6b6048633bd60ae0dd046bcb14044066eacacfa58a88d4c9ff00da45394473f0"
           }
  end

  test "fingerprints change with behavior or evaluation fields" do
    {:ok, original} = CaseSet.fetch("rag_structured_extract")

    mutations = [
      %{original | version: original.version + 1},
      %{original | category: "different_category"},
      %{original | system_prompt: original.system_prompt <> " Be brief."},
      %{original | context: original.context <> "\nAdditional context."},
      %{original | question: original.question <> " Include all facts."},
      %{original | response_format: original.response_format <> " Use compact JSON."},
      %{
        original
        | checks:
            original.checks ++ [%{"type" => "required_source_ids", "source_ids" => ["brief-7"]}]
      }
    ]

    assert Enum.all?(mutations, &(CaseSet.fingerprint(&1) != original.fingerprint))
  end

  test "fingerprints ignore descriptions, tags, and the existing fingerprint" do
    {:ok, original} = CaseSet.fetch("rag_structured_extract")

    metadata_only_change = %{
      original
      | description: "A clearer explanation for a human reader",
        tags: ["new-tag"],
        fingerprint: String.duplicate("f", 64)
    }

    assert CaseSet.fingerprint(metadata_only_change) == original.fingerprint
  end

  test "fingerprints do not depend on nested map insertion order" do
    {:ok, original} = CaseSet.fetch("rag_structured_extract")
    [check] = original.checks

    reordered_check = check |> Map.to_list() |> Enum.reverse() |> Map.new()
    reordered = %{original | checks: [reordered_check]}

    assert CaseSet.fingerprint(reordered) == original.fingerprint
  end

  test "rejects duplicate case IDs" do
    [first | _rest] = CaseSet.all()

    assert {:error, %{type: :invalid_case_set, reason: :duplicate_case_ids}} =
             CaseSet.validate([first, first])
  end

  test "rejects a stale fingerprint" do
    [first | _rest] = CaseSet.all()
    stale = %{first | question: first.question <> " Changed."}

    assert {:error,
            %{
              type: :fingerprint_mismatch,
              case_id: "rag_structured_extract",
              actual: original_fingerprint
            }} = CaseSet.validate([stale])

    assert original_fingerprint == first.fingerprint
  end

  test "rejects malformed deterministic check specifications" do
    [first | _rest] = CaseSet.all()

    invalid = %{
      first
      | checks: [%{"type" => "required_fact", "id" => "date", "any_of" => []}]
    }

    invalid = %{invalid | fingerprint: CaseSet.fingerprint(invalid)}

    assert {:error,
            %{
              type: :invalid_check_spec,
              case_id: "rag_structured_extract",
              check_index: 0,
              reason: :invalid_fact_alternatives
            }} = CaseSet.validate([invalid])
  end

  test "rejects malformed grouped fact checks" do
    [first | _rest] = CaseSet.all()

    invalid = %{
      first
      | checks: [
          %{
            "type" => "required_fact_groups",
            "id" => "related_facts",
            "groups" => [["phase one"], []],
            "max_span_tokens" => 0
          }
        ]
    }

    invalid = %{invalid | fingerprint: CaseSet.fingerprint(invalid)}

    assert {:error,
            %{
              type: :invalid_check_spec,
              check_index: 0,
              reason: :invalid_fact_groups
            }} = CaseSet.validate([invalid])
  end

  test "open synthesis intentionally has no exact expected answer" do
    {:ok, synthesis} = CaseSet.fetch("rag_open_synthesis")

    refute Enum.any?(synthesis.checks, &(&1["type"] == "json_equals"))
    assert Enum.any?(synthesis.checks, &(&1["type"] == "required_fact"))
    assert Enum.any?(synthesis.checks, &(&1["type"] == "required_fact_groups"))
    assert Enum.any?(synthesis.checks, &(&1["type"] == "required_source_ids"))
  end
end
