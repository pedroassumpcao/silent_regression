defmodule SilentRegression.Contracts.ConformanceTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Contracts
  alias SilentRegression.Contracts.{Evaluation, Parser, RuleResult}

  @evaluated_at ~U[2026-09-15 12:00:00.000000Z]
  @fixture_directory "test/fixtures/contracts/v1"
  @categories ~w(positive negative malformed_output boundary adversarial)
  @statuses ~w(pass fail evaluator_error)

  test "approved conformance fixture set covers every version-1 primitive" do
    fixture_set = load_fixture_set!("conformance.json")
    validate_fixture_set!(fixture_set, "conformance")

    covered_types =
      fixture_set["contracts"]
      |> Enum.flat_map(&rule_types(&1["contract"]["root"]))
      |> Enum.uniq()
      |> Enum.sort()

    assert covered_types == Enum.sort(Parser.rule_types())

    assert Enum.sort(Enum.uniq(Enum.map(fixture_set["fixtures"], & &1["category"]))) ==
             Enum.sort(@categories)
  end

  test "approved conformance judgments match deterministic-v1" do
    fixture_set = load_fixture_set!("conformance.json")
    validate_fixture_set!(fixture_set, "conformance")
    evaluate_fixture_set!(fixture_set)
  end

  test "held-out fixture structure is frozen without evaluating candidate outcomes" do
    fixture_set = load_fixture_set!("heldout.json")
    validate_fixture_set!(fixture_set, "heldout")

    case fixture_set["status"] do
      "candidate" -> assert length(fixture_set["fixtures"]) == 11
      "approved" -> evaluate_fixture_set!(fixture_set)
    end
  end

  defp load_fixture_set!(filename) do
    @fixture_directory
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  defp validate_fixture_set!(fixture_set, split) do
    assert Enum.sort(Map.keys(fixture_set)) ==
             Enum.sort(~w(fixture_schema_version split status contracts fixtures))

    assert fixture_set["fixture_schema_version"] == 1
    assert fixture_set["split"] == split
    assert fixture_set["status"] in ~w(candidate approved)
    assert is_list(fixture_set["contracts"]) and fixture_set["contracts"] != []
    assert is_list(fixture_set["fixtures"]) and fixture_set["fixtures"] != []

    contract_keys = Enum.map(fixture_set["contracts"], & &1["key"])
    fixture_ids = Enum.map(fixture_set["fixtures"], & &1["id"])
    assert Enum.uniq(contract_keys) == contract_keys
    assert Enum.uniq(fixture_ids) == fixture_ids

    contracts_by_key =
      Map.new(fixture_set["contracts"], fn contract_entry ->
        assert Enum.sort(Map.keys(contract_entry)) == ["contract", "key"]
        assert is_binary(contract_entry["key"]) and contract_entry["key"] != ""
        assert {:ok, contract} = Contracts.parse_contract(contract_entry["contract"])
        {contract_entry["key"], contract}
      end)

    for fixture <- fixture_set["fixtures"] do
      assert Enum.sort(Map.keys(fixture)) ==
               Enum.sort(
                 ~w(id domain category contract_key output_text expected_status expected_rule_statuses)
               )

      assert is_binary(fixture["id"]) and fixture["id"] != ""
      assert is_binary(fixture["domain"]) and fixture["domain"] != ""
      assert fixture["category"] in @categories
      assert is_binary(fixture["output_text"])
      assert fixture["expected_status"] in @statuses
      assert is_map(fixture["expected_rule_statuses"])

      assert Enum.all?(fixture["expected_rule_statuses"], fn {_rule_id, status} ->
               status in @statuses
             end)

      contract = Map.fetch!(contracts_by_key, fixture["contract_key"])
      expected_rule_ids = contract.root |> rule_ids() |> Enum.sort()
      assert Enum.sort(Map.keys(fixture["expected_rule_statuses"])) == expected_rule_ids
    end
  end

  defp evaluate_fixture_set!(fixture_set) do
    contracts_by_key =
      Map.new(fixture_set["contracts"], fn contract_entry ->
        {:ok, contract} = Contracts.parse_contract(contract_entry["contract"])
        {contract_entry["key"], contract}
      end)

    for fixture <- fixture_set["fixtures"] do
      contract = Map.fetch!(contracts_by_key, fixture["contract_key"])

      {:ok, observation} =
        Contracts.new_observation(%{
          "id" => fixture["id"],
          "output_text" => fixture["output_text"]
        })

      options = [evaluation_id: "evaluation-#{fixture["id"]}", evaluated_at: @evaluated_at]
      assert {:ok, evaluation} = Contracts.evaluate(contract, observation, options)
      assert Atom.to_string(evaluation.status) == fixture["expected_status"], fixture["id"]

      actual_rule_statuses =
        Map.new(evaluation.rule_results, fn result ->
          assert is_binary(result.explanation) and result.explanation != ""
          assert is_map(result.evidence)
          assert {:ok, _encoded} = Jason.encode(RuleResult.to_map(result))
          {result.rule_id, Atom.to_string(result.status)}
        end)

      assert actual_rule_statuses == fixture["expected_rule_statuses"], fixture["id"]

      assert {:ok, repeated} = Contracts.evaluate(contract, observation, options)
      assert Evaluation.to_map(repeated) == Evaluation.to_map(evaluation), fixture["id"]
    end
  end

  defp rule_ids(%{"type" => type, "rules" => rules} = rule) when type in ["all", "any"] do
    [rule["id"] | Enum.flat_map(rules, &rule_ids/1)]
  end

  defp rule_ids(%{"type" => "not", "rule" => child} = rule),
    do: [rule["id"] | rule_ids(child)]

  defp rule_ids(rule), do: [rule["id"]]

  defp rule_types(%{"type" => type, "rules" => rules}) when type in ["all", "any"] do
    [type | Enum.flat_map(rules, &rule_types/1)]
  end

  defp rule_types(%{"type" => "not", "rule" => child}), do: ["not" | rule_types(child)]
  defp rule_types(rule), do: [rule["type"]]
end
