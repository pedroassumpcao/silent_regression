defmodule SilentRegression.Spike.SemanticLayer.ContractRescoreTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.Spike.SemanticLayer.ContractRescore
  alias SilentRegression.Spike.SemanticLayer.ContractRescoreResult
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage

  @tuning_path "test/fixtures/drift_spike/semantic_layer/approved/tuning-pairs.json"
  @candidate_path "test/fixtures/drift_spike/semantic_layer/candidates/tuning-pairs.json"

  test "rescoring preserves all authoring and tuning judgments with explanations" do
    {:ok, authoring} = FixtureSet.load()
    {:ok, tuning} = SemanticStorage.read(@tuning_path)

    assert {:ok, result} =
             ContractRescore.run(authoring, tuning, file_sha256(@tuning_path),
               clock: fn -> ~U[2026-09-11 12:00:00Z] end,
               evaluation_id: "semantic-contract-rescore-tuning",
               git_revision: "abc123"
             )

    assert result.provider_calls == 0
    assert result.summary["fixture_count"] == 88
    assert result.summary["matched_expectation_count"] == 88
    assert result.summary["expected_pass_count"] == 52
    assert result.summary["expected_pass_matched_count"] == 52
    assert result.summary["actual_pass_count"] == 52
    assert result.summary["expected_fail_count"] == 36
    assert result.summary["expected_fail_matched_count"] == 36
    assert result.summary["actual_fail_count"] == 36
    assert :ok = ContractRescoreResult.validate(result)

    assert Enum.all?(result.results, fn fixture_result ->
             fixture_result["matched_expectation"] and fixture_result["checks"] != [] and
               Enum.all?(fixture_result["checks"], &is_binary(&1["reason"]))
           end)

    failure_modes = Map.new(result.summary["by_failure_mode"], &{&1["failure_mode"], &1})

    for failure_mode <- ~w(wrong_attribution unsupported_claim omission failed_abstention) do
      assert failure_modes[failure_mode]["detected_count"] ==
               failure_modes[failure_mode]["fixture_count"]
    end

    tampered_summary =
      result
      |> ContractRescoreResult.to_map()
      |> put_in(["summary", "fixture_count"], 87)

    assert {:error, %{field: :summary, reason: :must_match_fixture_results}} =
             ContractRescoreResult.from_map(tampered_summary)
  end

  test "refuses an unapproved paired fixture source" do
    {:ok, authoring} = FixtureSet.load()
    {:ok, candidate} = SemanticStorage.read(@candidate_path)

    assert {:error, %{"type" => "invalid_fixture_source"}} =
             ContractRescore.run(authoring, candidate, file_sha256(@candidate_path))
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
