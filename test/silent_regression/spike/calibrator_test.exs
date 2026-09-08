defmodule SilentRegression.Spike.CalibratorTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Calibrator
  alias SilentRegression.SpikeFixtures

  test "builds the same auditable threshold artifact for the same seed" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: baseline_outputs()})

    controls = [
      SpikeFixtures.analyzed_run(%{
        run_id: "control-1",
        condition: "control",
        outputs: ["apple red", "fruit red", "fruit apple", "berry red"]
      }),
      SpikeFixtures.analyzed_run(%{
        run_id: "control-2",
        condition: "control",
        outputs: ["red berry", "apple fruit", "red apple", "red fruit"]
      })
    ]

    options = [
      seed: 82,
      iterations: 40,
      quantile: 0.95,
      calibration_id: "frozen-calibration",
      clock: &fixed_clock/0,
      git_revision: "abc123"
    ]

    assert {:ok, first} = Calibrator.build(baseline, controls, options)
    assert {:ok, second} = Calibrator.build(baseline, controls, options)
    assert first == second
    assert first.baseline_run_id == "baseline"
    assert first.control_run_ids == ["control-1", "control-2"]
    assert first.source_run_ids == ["baseline", "control-1", "control-2"]
    assert first.settings["seed"] == 82
    assert first.settings["iterations"] == 40
    assert first.settings["baseline_group_size"] == 4
    assert first.settings["control_group_size"] == 4

    [threshold] = first.thresholds
    assert threshold["case_id"] == "rag_open_synthesis"
    assert length(threshold["null_energies"]) == 40

    assert threshold["source_sample_counts"] == %{
             "baseline" => 4,
             "control-1" => 4,
             "control-2" => 4
           }

    assert threshold["empirical_exceedance_rate"] <= 0.05
    assert is_binary(Jason.encode!(SilentRegression.Spike.Calibration.to_map(first)))
  end

  test "rejects incompatible and duplicate controls" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: baseline_outputs()})

    incompatible =
      SpikeFixtures.analyzed_run(%{
        run_id: "control",
        condition: "control",
        requested_model: "different-model",
        outputs: baseline_outputs()
      })

    assert {:error, error} = Calibrator.build(baseline, [incompatible], seed: 1)
    assert error["type"] == "incompatible_provenance"

    control =
      SpikeFixtures.analyzed_run(%{
        run_id: "control",
        condition: "control",
        outputs: baseline_outputs()
      })

    assert {:error, duplicate_error} = Calibrator.build(baseline, [control, control], seed: 1)
    assert duplicate_error["type"] == "configuration_error"
  end

  test "rejects incomplete source pools instead of changing the resample shape" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: baseline_outputs()})

    incomplete =
      SpikeFixtures.analyzed_run(%{
        run_id: "control",
        condition: "control",
        outputs: baseline_outputs(),
        finish_reasons: ["completed", "completed", "completed", "max_output_tokens"]
      })

    assert {:error, error} = Calibrator.build(baseline, [incomplete], seed: 1)
    assert error["type"] == "incomplete_calibration_source"
    assert error["details"]["run_id"] == "control"
  end

  test "requires only null control conditions and an explicit seed" do
    baseline = SpikeFixtures.analyzed_run(%{run_id: "baseline", outputs: baseline_outputs()})

    regression =
      SpikeFixtures.analyzed_run(%{
        run_id: "regression",
        condition: "subtle_regression",
        outputs: baseline_outputs()
      })

    assert {:error, condition_error} = Calibrator.build(baseline, [regression], seed: 1)
    assert condition_error["type"] == "configuration_error"

    assert {:error, seed_error} = Calibrator.build(baseline, [], [])
    assert seed_error["type"] == "configuration_error"
  end

  defp baseline_outputs, do: ["red apple", "red fruit", "apple fruit", "red berry"]
  defp fixed_clock, do: ~U[2026-09-07 13:00:00Z]
end
