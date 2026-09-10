defmodule SilentRegression.Spike.ReportTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.FixtureComparison
  alias SilentRegression.Spike.FixtureComparisonStorage
  alias SilentRegression.Spike.FixtureSet
  alias SilentRegression.Spike.Report
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFixtures

  @tag :tmp_dir
  test "reproduces a complete summary, ignores unrelated JSON, and warns on bad artifacts", %{
    tmp_dir: tmp_dir
  } do
    sources = write_sources(tmp_dir)
    File.write!(Path.join(tmp_dir, "unrelated.json"), Jason.encode!(%{"hello" => "world"}))
    File.write!(Path.join(tmp_dir, "malformed.json"), "{not-json")

    historical =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "historical-baseline",
        condition: "baseline",
        sample_size: 30
      })

    incompatible =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "incompatible-control",
        condition: "control",
        provider: "other-provider",
        sample_size: 20
      })

    :ok = Storage.write(Path.join(tmp_dir, "historical.json"), historical)
    :ok = Storage.write(Path.join(tmp_dir, "incompatible.json"), incompatible)

    assert {:ok, first} = Report.build(sources.paths)
    assert {:ok, second} = Report.build(sources.paths)
    assert first["markdown"] == second["markdown"]
    assert first["verdict"] == Report.pending_verdict()
    assert first["artifact_scan"]["included_run_count"] == 3
    assert first["artifact_scan"]["warning_count"] == 3

    warning_types = MapSet.new(first["artifact_scan"]["warnings"], & &1["type"])
    assert warning_types == MapSet.new(~w(malformed_json non_selected_baseline incompatible_run))

    markdown = first["markdown"]
    assert markdown =~ "# Silent Regression Feasibility Spike Summary"
    assert markdown =~ "**Human verdict:** `PENDING_HUMAN_VERDICT`"
    assert markdown =~ "## Baseline health by case"
    assert markdown =~ "## Control comparisons by case"
    assert markdown =~ "## Fixture comparisons by case and condition"
    assert markdown =~ "Harmless/style drift-review rate:"
    assert markdown =~ "28/28 approved fixtures"
    refute markdown =~ "Provider calls made by this report: 0"
    refute markdown =~ "unrelated.json"
    refute markdown =~ "Meridian Lantern"

    summary_path = Path.join(tmp_dir, "SUMMARY.md")
    assert :ok = Report.write(summary_path, markdown)
    assert File.read!(summary_path) == markdown
    assert {:error, %{type: :already_exists}} = Report.write(summary_path, markdown)
    assert File.read!(sources.calibration) == sources.calibration_bytes
  end

  @tag :tmp_dir
  test "rejects unsupported verdicts and incompatible anchor identities", %{tmp_dir: tmp_dir} do
    sources = write_sources(tmp_dir)

    assert {:error, error} = Report.build(sources.paths, verdict: "MAYBE")
    assert error["type"] == "configuration_error"

    assert {:ok, approved} =
             Report.build(sources.paths, verdict: "NEEDS_A_SEMANTIC_LAYER")

    assert approved["markdown"] =~ "**Human verdict:** `NEEDS_A_SEMANTIC_LAYER`"
    assert approved["markdown"] =~ "--verdict NEEDS_A_SEMANTIC_LAYER"

    fixture_report =
      sources.fixture_report
      |> Map.put("baseline_run_id", "some-other-baseline")

    incompatible_path = Path.join(tmp_dir, "incompatible-fixture-comparison.json")
    :ok = FixtureComparisonStorage.write(incompatible_path, fixture_report)

    paths = Map.put(sources.paths, "fixture_comparison_path", incompatible_path)
    assert {:error, error} = Report.build(paths)
    assert error["type"] == "incompatible_report_source"
    assert error["details"]["field"] == "fixture_comparison.baseline_run_id"
  end

  defp write_sources(tmp_dir) do
    baseline =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "baseline",
        condition: "baseline",
        sample_size: 30
      })

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
        permutations: 19,
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

    %{
      paths: %{
        "results_directory" => tmp_dir,
        "baseline_path" => baseline_path,
        "calibration_path" => calibration_path,
        "fixture_comparison_path" => fixture_path
      },
      calibration: calibration_path,
      calibration_bytes: File.read!(calibration_path),
      fixture_report: fixture_report
    }
  end
end
