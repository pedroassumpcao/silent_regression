defmodule Mix.Tasks.DriftSpike.ReportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.Report, as: ReportTask
  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.FixtureComparison
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
  test "writes a pending human-verdict report without provider calls", %{tmp_dir: tmp_dir} do
    paths = write_sources(tmp_dir)
    output_path = Path.join(tmp_dir, "SUMMARY.md")
    File.write!(Path.join(tmp_dir, "malformed.json"), "{not-json")

    output =
      capture_io(fn ->
        ReportTask.run([
          "--results",
          tmp_dir,
          "--baseline",
          paths.baseline,
          "--calibration",
          paths.calibration,
          "--fixture-comparison",
          paths.fixture,
          "--output",
          output_path
        ])
      end)

    assert output =~ "Drift spike feasibility summary captured"
    assert output =~ "Human verdict: PENDING_HUMAN_VERDICT"
    assert output =~ "Provider calls made by this report: 0"
    assert output =~ "Warning [malformed_json] malformed.json"
    assert File.read!(output_path) =~ "**Human verdict:** `PENDING_HUMAN_VERDICT`"

    assert_raise Mix.Error, ~r/already_exists/, fn ->
      capture_io(fn ->
        ReportTask.run([
          "--results",
          tmp_dir,
          "--baseline",
          paths.baseline,
          "--calibration",
          paths.calibration,
          "--fixture-comparison",
          paths.fixture,
          "--output",
          output_path
        ])
      end)
    end
  end

  defp write_sources(tmp_dir) do
    baseline = SpikeFixtures.analyzed_case_set_run(%{run_id: "baseline", sample_size: 30})

    calibration_source =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "calibration-source",
        condition: "control",
        sample_size: 20
      })

    heldout =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "heldout",
        condition: "control",
        sample_size: 20
      })

    calibration = SpikeFixtures.calibration_for(baseline)
    {:ok, fixture_set} = FixtureSet.load()

    {:ok, fixture_report} =
      FixtureComparison.run(baseline, calibration, heldout, fixture_set,
        seed: 91,
        permutations: 9,
        comparison_id: "fixture-comparison",
        clock: fn -> ~U[2026-09-10 12:00:00Z] end,
        git_revision: "def5678"
      )

    baseline_path = Path.join(tmp_dir, "baseline.json")
    calibration_source_path = Path.join(tmp_dir, "calibration-source.json")
    heldout_path = Path.join(tmp_dir, "heldout.json")
    calibration_path = Path.join(tmp_dir, "calibration.json")
    fixture_path = Path.join(tmp_dir, "fixture-comparison.json")

    :ok = Storage.write(baseline_path, baseline)
    :ok = Storage.write(calibration_source_path, calibration_source)
    :ok = Storage.write(heldout_path, heldout)
    :ok = CalibrationStorage.write(calibration_path, calibration)
    :ok = FixtureComparisonStorage.write(fixture_path, fixture_report)

    %{baseline: baseline_path, calibration: calibration_path, fixture: fixture_path}
  end
end
