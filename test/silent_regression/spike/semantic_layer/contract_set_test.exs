defmodule SilentRegression.Spike.SemanticLayer.ContractSetTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.Spike.SemanticLayer.ContractEvaluator
  alias SilentRegression.Spike.SemanticLayer.ContractSet
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage

  @tuning_path "test/fixtures/drift_spike/semantic_layer/approved/tuning-pairs.json"

  test "defines a valid JSON-compatible contract for every frozen RAG case" do
    assert :ok = ContractSet.validate()

    assert Enum.map(ContractSet.all(), & &1["case_id"]) == [
             "rag_structured_extract",
             "rag_answer_with_citations",
             "rag_abstain_when_unsupported",
             "rag_open_synthesis"
           ]

    assert ContractSet.metadata()["contract_set_id"] == "rag-semantic-contracts-v1"
    assert ContractSet.metadata()["contract_set_version"] == 1

    assert ContractSet.fingerprint() ==
             "ed622e2939fff8a3d8090f741242cc44fba8caab793833d56c26b4416b69b2cd"

    assert is_binary(Jason.encode!(ContractSet.all()))
  end

  test "rejects changed contract data and stale source-case provenance" do
    {:ok, contract} = ContractSet.fetch("rag_open_synthesis")

    changed = put_in(contract, ["checks", Access.at(0), "allowed_source_ids"], ["other"])

    assert {:error, %{reason: :fingerprint_mismatch}} =
             ContractSet.validate_contract(changed)

    stale = Map.put(contract, "source_case_fingerprint", String.duplicate("0", 64))

    assert {:error, %{reason: :stale_source_case}} =
             ContractSet.validate_contract(stale)
  end

  test "matches every Task 10 authoring judgment with explainable failures" do
    assert {:ok, fixture_set} = FixtureSet.load()

    results =
      Enum.map(fixture_set["fixtures"], fn fixture ->
        {:ok, contract} = ContractSet.fetch(fixture["case_id"])
        {:ok, evaluation} = ContractEvaluator.evaluate(contract, fixture["output_text"])
        expected_pass = fixture["intended_label"] == "acceptable"

        assert evaluation["all_passed"] == expected_pass,
               mismatch_message(fixture["id"], expected_pass, evaluation)

        if expected_pass == false do
          assert Enum.any?(evaluation["checks"], &(&1["passed"] == false))
          assert Enum.all?(evaluation["checks"], &is_binary(&1["reason"]))
        end

        {fixture, evaluation}
      end)

    for failure_mode <- ~w(wrong_attribution unsupported_claim omission failed_abstention) do
      assert Enum.any?(results, fn {fixture, evaluation} ->
               failure_mode in fixture["failure_modes"] and evaluation["all_passed"] == false
             end)
    end
  end

  test "matches every approved tuning judgment before held-out evaluation" do
    assert {:ok, fixture_set} = SemanticStorage.read(@tuning_path)
    assert fixture_set.status == "approved"
    assert Enum.all?(fixture_set.fixtures, &(&1["split"] == "tuning"))

    Enum.each(fixture_set.fixtures, fn fixture ->
      {:ok, contract} = ContractSet.fetch(fixture["case_id"])
      {:ok, evaluation} = ContractEvaluator.evaluate(contract, fixture["output_text"])

      assert evaluation["all_passed"] == fixture["expected_contract_pass"],
             mismatch_message(
               fixture["fixture_id"],
               fixture["expected_contract_pass"],
               evaluation
             )
    end)
  end

  defp mismatch_message(fixture_id, expected_pass, evaluation) do
    failures =
      evaluation["checks"]
      |> Enum.reject(& &1["passed"])
      |> Enum.map(&{&1["check_id"], &1["reason"]})

    "fixture #{fixture_id} expected pass=#{expected_pass}; failures=#{inspect(failures)}"
  end
end
