defmodule SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfig do
  @moduledoc """
  Frozen Task D inputs and decision settings.

  The September 9 and September 10 parent controls are reserved for tuning and
  held-out fixtures respectively, so neither may enter representation fitting
  or null-threshold calibration.
  """

  alias SilentRegression.Spike.SemanticLayer.Representation

  @case_id "rag_open_synthesis"
  @baseline %{
    path: "results/drift_spike/baseline-20260908T135803Z-1.json",
    run_id: "baseline-20260908T135803Z-1",
    condition: "baseline",
    artifact_sha256: "298d1614f415d071b2c9c3d5f7467e4234b4e92233a7d8f5238d68f026af228c"
  }
  @fit_controls [
    %{
      path: "results/drift_spike/control-20260908T141227Z-1.json",
      run_id: "control-20260908T141227Z-1",
      condition: "control",
      artifact_sha256: "1e3d900ddb378bc0d5893fe3dca2279360edeceff14cd79f0d5bd6b40ca28d35"
    },
    %{
      path: "results/drift_spike/control-20260909T005844Z-1.json",
      run_id: "control-20260909T005844Z-1",
      condition: "control",
      artifact_sha256: "29222c02e7d7e0a507b537274b439f94ae856c4960da965b22f3485a2f1eafa2"
    }
  ]
  @tuning %{
    path: "test/fixtures/drift_spike/semantic_layer/approved/tuning-pairs.json",
    fixture_set_id: "semantic-pairs-tuning-control-20260909T143004Z-1-v1-approved",
    source_run_id: "control-20260909T143004Z-1",
    artifact_sha256: "0fb83b02e6573ceadb058aa9900b1ab717f888d3f09a25d274c6e72991d712e4"
  }
  @heldout %{
    path: "test/fixtures/drift_spike/semantic_layer/approved/heldout-pairs.json",
    fixture_set_id: "semantic-pairs-heldout-control-20260910T042832Z-1-v1-approved",
    source_run_id: "control-20260910T042832Z-1",
    artifact_sha256: "6fdbfef04ee5a23c90223c295406982f39fbb4ccbc4cc912d6d2fc4ce4c7614b"
  }
  @settings %{
    tuning_iteration: 2,
    calibration_seed: 20_260_907,
    calibration_iterations: 2_000,
    quantile: 0.95,
    adjusted_p_alpha: 0.05,
    evaluation_seeds: [20_260_907, 20_260_917, 20_260_927],
    permutations: 999,
    harmless_review_rate_maximum: 0.10,
    subtle_review_rate_minimum: 1.0,
    require_seed_stability: true,
    multiple_comparison_family: "all_representation_batch_comparisons_per_seed"
  }

  @spec case_id() :: String.t()
  def case_id, do: @case_id

  @spec baseline() :: map()
  def baseline, do: @baseline

  @spec fit_controls() :: [map()]
  def fit_controls, do: @fit_controls

  @spec tuning() :: map()
  def tuning, do: @tuning

  @spec heldout() :: map()
  def heldout, do: @heldout

  @spec settings() :: map()
  def settings, do: @settings

  @spec representation_modules() :: [module()]
  def representation_modules, do: Representation.methods()

  @spec excluded_fit_run_ids() :: [String.t()]
  def excluded_fit_run_ids, do: [@tuning.source_run_id, @heldout.source_run_id]

  @spec output_directory() :: Path.t()
  def output_directory, do: "results/drift_spike/semantic-layer"
end
