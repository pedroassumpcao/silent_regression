defmodule SilentRegression.Spike.FixtureComparisonTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.FixtureComparison
  alias SilentRegression.Spike.FixtureComparisonStorage
  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.SpikeFixtures

  @tag :tmp_dir
  test "evaluates approved batches locally and leaves frozen calibration bytes unchanged", %{
    tmp_dir: tmp_dir
  } do
    baseline =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "baseline",
        condition: "baseline",
        sample_size: 30
      })

    heldout =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "heldout",
        condition: "control",
        sample_size: 20
      })

    calibration = SpikeFixtures.calibration_for(baseline)
    calibration_path = Path.join(tmp_dir, "calibration.json")
    report_path = Path.join(tmp_dir, "fixture-comparison.json")
    :ok = CalibrationStorage.write(calibration_path, calibration)
    frozen_bytes = File.read!(calibration_path)
    {:ok, persisted_calibration} = CalibrationStorage.read(calibration_path)
    {:ok, fixture_set} = FixtureSet.load()

    assert {:ok, report} =
             FixtureComparison.run(
               baseline,
               persisted_calibration,
               heldout,
               fixture_set,
               seed: 91,
               permutations: 39,
               comparison_id: "fixture-comparison",
               clock: fn -> ~U[2026-09-10 12:00:00Z] end,
               git_revision: "def5678"
             )

    assert File.read!(calibration_path) == frozen_bytes
    assert report["artifact_type"] == "fixture_comparison"
    assert report["provider_calls"] == 0
    assert report["baseline_run_id"] == "baseline"
    assert report["calibration_id"] == "frozen-calibration"
    assert report["control_run_id"] == "heldout"
    assert length(report["batches"]) == 7
    assert report["summary"]["case_comparison_count"] == 28

    assert Enum.all?(report["batches"], fn batch ->
             run = batch["candidate_run"]

             length(run["samples"]) == 80 and run["totals"]["actual_calls"] == 0 and
               Enum.all?(run["samples"], &(&1["origin"]["batch_id"] == batch["batch_id"]))
           end)

    mixed =
      report["batches"]
      |> Enum.find(&(&1["batch_id"] == "mixed_regression_25"))

    assert mixed["candidate_run"]["totals"]["approved_fixture_samples"] == 20
    assert mixed["candidate_run"]["totals"]["heldout_control_samples"] == 60

    assert Enum.all?(mixed["comparison"]["by_case"], fn result ->
             result["seeded_samples"]["seeded_regression_samples"] == 5 and
               result["seeded_samples"]["seeded_regression_rate"] == 0.25
           end)

    outcomes =
      report["batches"]
      |> Enum.flat_map(&get_in(&1, ["comparison", "by_case"]))
      |> Enum.map(& &1["alert_outcome"])
      |> MapSet.new()

    assert MapSet.member?(outcomes, "no_alert")
    assert MapSet.member?(outcomes, "drift_review")
    assert MapSet.member?(outcomes, "deterministic_regression")

    assert :ok = FixtureComparisonStorage.write(report_path, report)
    assert {:ok, ^report} = FixtureComparisonStorage.read(report_path)
    assert File.read!(calibration_path) == frozen_bytes

    assert {:error, %{type: :already_exists}} =
             FixtureComparisonStorage.write(report_path, report)
  end

  test "rejects a held-out control that was used to freeze calibration" do
    baseline = SpikeFixtures.analyzed_case_set_run(%{run_id: "baseline", sample_size: 30})

    heldout =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "calibration-source",
        condition: "control",
        sample_size: 20
      })

    calibration = SpikeFixtures.calibration_for(baseline)
    {:ok, fixture_set} = FixtureSet.load()

    assert {:error, error} =
             FixtureComparison.run(baseline, calibration, heldout, fixture_set,
               seed: 91,
               permutations: 9
             )

    assert error["type"] == "calibration_leakage"
  end

  @tag :tmp_dir
  test "storage returns structured errors for malformed comparison artifacts", %{tmp_dir: tmp_dir} do
    invalid_json_path = Path.join(tmp_dir, "invalid-json.json")
    invalid_report_path = Path.join(tmp_dir, "invalid-report.json")
    File.write!(invalid_json_path, "{invalid")
    File.write!(invalid_report_path, Jason.encode!(%{"schema_version" => 1}))

    assert {:error, %{type: :invalid_json}} =
             FixtureComparisonStorage.read(invalid_json_path)

    assert {:error, %{type: :invalid_artifact}} =
             FixtureComparisonStorage.read(invalid_report_path)
  end
end
