defmodule SilentRegression.Spike.SemanticLayer.CheapBenchmarkFreezeTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkFreeze
  alias SilentRegression.Spike.SemanticLayer.Storage

  test "pins a passing tuning selection and every final-evaluation input" do
    assert {:ok, freeze} = CheapBenchmarkFreeze.load()

    assert freeze["selection_policy"]["heldout_labels_used"] == false

    assert freeze["selection_policy"]["selected_representation_ids"] == [
             "semantic-representation-field-aware-v2"
           ]

    assert_file_hash(freeze["tuning_result"])
    assert_file_hash(freeze["selected_representation"])
    assert_file_hash(freeze["calibration"])
    assert_file_hash(freeze["heldout_fixture_set"])

    assert {:ok, tuning} = read_benchmark(freeze["tuning_result"]["path"])
    assert tuning.evaluation_role == "method_selection"
    assert tuning.summary["gate_status"] == "passed"

    assert tuning.summary["selected_representation_ids"] ==
             freeze["selection_policy"]["selected_representation_ids"]
  end

  test "rejects any post-freeze setting or selected-method change" do
    assert {:ok, freeze} = CheapBenchmarkFreeze.load()

    changed_seed = put_in(freeze, ["settings", "seeds", Access.at(0)], 999)
    assert {:error, %{type: :settings_mismatch}} = CheapBenchmarkFreeze.validate(changed_seed)

    changed_method = put_in(freeze, ["selected_representation", "method_version"], 99)

    assert {:error, %{type: :invalid_selected_representation}} =
             CheapBenchmarkFreeze.validate(changed_method)
  end

  defp read_benchmark(path) do
    case Storage.read(path) do
      {:ok, %BenchmarkResult{} = result} -> {:ok, result}
      other -> other
    end
  end

  defp assert_file_hash(reference) do
    assert {:ok, contents} = File.read(reference["path"])
    actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    assert actual == reference["artifact_sha256"]
  end
end
