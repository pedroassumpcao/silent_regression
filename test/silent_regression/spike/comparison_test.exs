defmodule SilentRegression.Spike.ComparisonTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Calibrator
  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Comparison
  alias SilentRegression.SpikeFixtures

  test "compares compatible runs reproducibly and corrects p-values across cases" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: null_outputs()})

    control =
      SpikeFixtures.analyzed_run(%{
        run_id: "control",
        condition: "control",
        outputs: Enum.reverse(null_outputs())
      })

    options = [seed: 91, permutations: 99]

    assert {:ok, first} = Comparison.compare(baseline, control, options)
    assert {:ok, second} = Comparison.compare(baseline, control, options)
    assert first == second
    assert first["baseline_run_id"] == "baseline"
    assert first["candidate_run_id"] == "control"

    assert first["summary"] == %{
             "case_count" => 1,
             "drift_review_count" => 0,
             "not_calibrated_count" => 1
           }

    [case_result] = first["by_case"]
    assert case_result["adjusted_p_value"] == case_result["p_value"]
    assert case_result["outcome"] == "not_calibrated"
    assert case_result["threshold"] == nil
    assert case_result["baseline_completed_samples"] == 4
    assert case_result["candidate_completed_samples"] == 4
  end

  test "rejects provider, behavior configuration, case, and returned-model mismatches" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: null_outputs()})
    {:ok, different_case} = CaseSet.fetch("rag_answer_with_citations")

    mismatches = [
      SpikeFixtures.analyzed_run(%{
        run_id: "provider",
        condition: "control",
        provider: "different",
        outputs: null_outputs()
      }),
      SpikeFixtures.analyzed_run(%{
        run_id: "model",
        condition: "control",
        requested_model: "different-model",
        returned_model: "fake-model",
        outputs: null_outputs()
      }),
      SpikeFixtures.analyzed_run(%{
        run_id: "configuration",
        condition: "control",
        request_config: %{"max_output_tokens" => 1024},
        outputs: null_outputs()
      }),
      SpikeFixtures.analyzed_run(%{
        run_id: "returned-model",
        condition: "control",
        returned_model: "different-snapshot",
        outputs: null_outputs()
      }),
      SpikeFixtures.analyzed_run(%{
        run_id: "case",
        condition: "control",
        case_definition: different_case,
        outputs: null_outputs()
      })
    ]

    for mismatch <- mismatches do
      assert {:error, error} = Comparison.compare(baseline, mismatch, seed: 1, permutations: 9)
      assert error["type"] == "incompatible_provenance"
    end
  end

  test "applies both threshold and adjusted-p gates to held-out outcomes" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: null_outputs()})

    calibration_control =
      SpikeFixtures.analyzed_run(%{
        run_id: "calibration-control",
        condition: "control",
        outputs: ["apple red", "fruit red", "apple fruit", "berry red"]
      })

    assert {:ok, calibration} =
             Calibrator.build(baseline, [calibration_control],
               seed: 12,
               iterations: 100,
               quantile: 0.95,
               calibration_id: "frozen",
               clock: &fixed_clock/0,
               git_revision: "abc123"
             )

    stable_control =
      SpikeFixtures.analyzed_run(%{
        run_id: "stable-held-out",
        condition: "control",
        outputs: ["red apple", "fruit red", "red fruit", "apple berry"]
      })

    drifted_control =
      SpikeFixtures.analyzed_run(%{
        run_id: "drifted-held-out",
        condition: "control",
        outputs: ["blue sky", "sky blue", "blue cloud", "cloud blue"]
      })

    assert {:ok, stable} =
             Comparison.compare(baseline, stable_control,
               seed: 44,
               permutations: 199,
               calibration: calibration
             )

    assert hd(stable["by_case"])["outcome"] == "no_drift_review"

    assert {:ok, drifted} =
             Comparison.compare(baseline, drifted_control,
               seed: 44,
               permutations: 199,
               calibration: calibration
             )

    drifted_case = hd(drifted["by_case"])
    assert drifted_case["above_threshold"]
    assert drifted_case["statistically_significant"]
    assert drifted_case["outcome"] == "drift_review"
  end

  test "refuses to evaluate a calibration source as held out" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: null_outputs()})

    source_control =
      SpikeFixtures.analyzed_run(%{
        run_id: "source-control",
        condition: "control",
        outputs: null_outputs()
      })

    assert {:ok, calibration} =
             Calibrator.build(baseline, [source_control],
               seed: 3,
               iterations: 20,
               calibration_id: "frozen",
               clock: &fixed_clock/0,
               git_revision: nil
             )

    assert {:error, error} =
             Comparison.compare(baseline, source_control,
               seed: 4,
               permutations: 19,
               calibration: calibration
             )

    assert error["type"] == "calibration_leakage"
  end

  test "refuses incomplete held-out pools that differ from the calibrated shape" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: null_outputs()})

    source_control =
      SpikeFixtures.analyzed_run(%{
        run_id: "source-control",
        condition: "control",
        outputs: null_outputs()
      })

    assert {:ok, calibration} =
             Calibrator.build(baseline, [source_control],
               seed: 3,
               iterations: 20,
               calibration_id: "frozen",
               clock: &fixed_clock/0,
               git_revision: nil
             )

    incomplete =
      SpikeFixtures.analyzed_run(%{
        run_id: "incomplete-held-out",
        condition: "control",
        outputs: null_outputs(),
        finish_reasons: ["completed", "completed", "completed", "max_output_tokens"]
      })

    assert {:error, error} =
             Comparison.compare(baseline, incomplete,
               seed: 4,
               permutations: 19,
               calibration: calibration
             )

    assert error["type"] == "incompatible_sample_shape"
  end

  defp null_outputs, do: ["red apple", "red fruit", "apple fruit", "red berry"]
  defp fixed_clock, do: ~U[2026-09-07 13:00:00Z]
end
