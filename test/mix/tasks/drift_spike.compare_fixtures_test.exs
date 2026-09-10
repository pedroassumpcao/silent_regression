defmodule Mix.Tasks.DriftSpike.CompareFixturesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.CompareFixtures
  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.FixtureComparisonStorage
  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFixtures

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  @tag :tmp_dir
  test "writes and prints a call-free approved fixture comparison", %{tmp_dir: tmp_dir} do
    paths = write_sources(tmp_dir)
    output_path = Path.join(tmp_dir, "report.json")

    output =
      capture_io(fn ->
        CompareFixtures.run([
          "--baseline",
          paths.baseline,
          "--calibration",
          paths.calibration,
          "--control",
          paths.control,
          "--seed",
          "91",
          "--permutations",
          "19",
          "--output",
          output_path
        ])
      end)

    assert output =~ "Drift spike fixture comparison captured"
    assert output =~ "Provider calls: 0"
    assert output =~ "Held-out control reference:"
    assert output =~ "Batch harmless_rewording"
    assert output =~ "Batch mixed_regression_50"
    assert output =~ "Mixed-regression sensitivity:"
    assert output =~ "Decision gate:"
    assert output =~ "No provider requests were made"

    assert {:ok, report} = FixtureComparisonStorage.read(output_path)
    assert report["provider_calls"] == 0
    assert length(report["batches"]) == 7
  end

  @tag :tmp_dir
  test "refuses candidate fixtures before producing a report", %{tmp_dir: tmp_dir} do
    paths = write_sources(tmp_dir)
    candidate_root = Path.join(Path.dirname(FixtureSet.official_root()), "candidates")
    output_path = Path.join(tmp_dir, "report.json")

    assert_raise Mix.Error, ~r/Official reports may use only.*unapproved_fixture_path/s, fn ->
      capture_io(fn ->
        CompareFixtures.run([
          "--baseline",
          paths.baseline,
          "--calibration",
          paths.calibration,
          "--control",
          paths.control,
          "--fixtures",
          candidate_root,
          "--seed",
          "91",
          "--permutations",
          "9",
          "--output",
          output_path
        ])
      end)
    end

    refute File.exists?(output_path)
  end

  defp write_sources(tmp_dir) do
    baseline = SpikeFixtures.analyzed_case_set_run(%{run_id: "baseline", sample_size: 30})

    control =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "heldout",
        condition: "control",
        sample_size: 20
      })

    calibration = SpikeFixtures.calibration_for(baseline)
    baseline_path = Path.join(tmp_dir, "baseline.json")
    control_path = Path.join(tmp_dir, "control.json")
    calibration_path = Path.join(tmp_dir, "calibration.json")
    :ok = Storage.write(baseline_path, baseline)
    :ok = Storage.write(control_path, control)
    :ok = CalibrationStorage.write(calibration_path, calibration)

    %{baseline: baseline_path, control: control_path, calibration: calibration_path}
  end
end
