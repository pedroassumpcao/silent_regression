defmodule SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfigTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfig

  test "freezes exact null, tuning, and held-out sources without overlap" do
    null_sources = [CheapBenchmarkConfig.baseline() | CheapBenchmarkConfig.fit_controls()]
    null_ids = Enum.map(null_sources, & &1.run_id)

    assert CheapBenchmarkConfig.tuning().source_run_id not in null_ids
    assert CheapBenchmarkConfig.heldout().source_run_id not in null_ids

    assert CheapBenchmarkConfig.excluded_fit_run_ids() == [
             CheapBenchmarkConfig.tuning().source_run_id,
             CheapBenchmarkConfig.heldout().source_run_id
           ]

    assert CheapBenchmarkConfig.tuning().fixture_set_id ==
             "semantic-pairs-tuning-control-20260909T143004Z-1-v1-approved"

    assert CheapBenchmarkConfig.heldout().fixture_set_id ==
             "semantic-pairs-heldout-control-20260910T042832Z-1-v1-approved"

    for source <- null_sources,
        do: assert_file_hash(source.path, source.artifact_sha256)

    assert_file_hash(
      CheapBenchmarkConfig.tuning().path,
      CheapBenchmarkConfig.tuning().artifact_sha256
    )

    assert_file_hash(
      CheapBenchmarkConfig.heldout().path,
      CheapBenchmarkConfig.heldout().artifact_sha256
    )
  end

  test "predeclares three distinct evaluation seeds and the complete correction family" do
    settings = CheapBenchmarkConfig.settings()
    assert length(settings.evaluation_seeds) == 3
    assert Enum.uniq(settings.evaluation_seeds) == settings.evaluation_seeds

    assert settings.multiple_comparison_family ==
             "all_representation_batch_comparisons_per_seed"
  end

  defp assert_file_hash(path, expected) do
    assert {:ok, contents} = File.read(path)
    actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    assert actual == expected
  end
end
