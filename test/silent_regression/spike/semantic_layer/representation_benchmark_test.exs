defmodule SilentRegression.Spike.SemanticLayer.RepresentationBenchmarkTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.SemanticLayer.Representation.FieldAware
  alias SilentRegression.Spike.SemanticLayer.RepresentationBenchmark
  alias SilentRegression.Spike.SemanticLayer.RepresentationCalibrator
  alias SilentRegression.SpikeFixtures

  test "selects a stable representation using tuning batches only" do
    baseline = run("baseline", "baseline", outputs("baseline", 19))
    control = run("null-control", "control", outputs("control", 19))
    bundle = calibrated_bundle(baseline, control)
    fixtures = paired_fixtures("tuning", "tuning-control")

    assert {:ok, result} =
             RepresentationBenchmark.run(
               baseline,
               fixtures,
               hash("fixtures"),
               [bundle],
               benchmark_options("method_selection")
             )

    assert result.evaluation_role == "method_selection"
    assert result.settings["provider_calls"] == 0
    assert result.settings["permutations"] == 199
    assert length(result.batches) == 3

    [method] = result.summary["by_representation"]
    assert method["harmless_drift_review_count"] == 0
    assert method["subtle_drift_review_count"] == 2
    assert method["stable_across_seeds"]
    assert method["passes_gate"]

    assert result.summary["selected_representation_ids"] == [
             bundle.spec.representation_id
           ]
  end

  test "enforces role partitions and refuses calibration-parent leakage" do
    baseline = run("baseline", "baseline", outputs("baseline", 19))
    control = run("null-control", "control", outputs("control", 19))
    bundle = calibrated_bundle(baseline, control)
    tuning = paired_fixtures("tuning", "tuning-control")

    assert {:error, %{type: :fixture_split_does_not_match_evaluation_role}} =
             RepresentationBenchmark.run(
               baseline,
               tuning,
               hash("fixtures"),
               [bundle],
               benchmark_options("final_evaluation")
             )

    leaky = %{tuning | source_control: Map.put(tuning.source_control, "run_id", "null-control")}

    assert {:error, %{type: :fixture_parent_run_leaked_into_calibration}} =
             RepresentationBenchmark.run(
               baseline,
               leaky,
               hash("fixtures"),
               [bundle],
               benchmark_options("method_selection")
             )
  end

  defp calibrated_bundle(baseline, control) do
    {:ok, bundle} =
      RepresentationCalibrator.build(
        FieldAware,
        %{run: baseline, artifact_sha256: hash("baseline")},
        [%{run: control, artifact_sha256: hash("control")}],
        case_id: "rag_open_synthesis",
        excluded_run_ids: ["tuning-control", "heldout-control"],
        seed: 3,
        iterations: 40,
        clock: &fixed_clock/0,
        git_revision: "abc123"
      )

    bundle
  end

  defp paired_fixtures(split, source_run_id) do
    fixtures =
      for parent <- 0..19,
          {label, value} <- [
            {"meaning_preserving", 19},
            {"style_only", 19},
            {"subtle_regression", 21}
          ] do
        %{
          "fixture_id" => "#{split}-#{parent}-#{label}",
          "parent_observation_id" => "#{source_run_id}:rag_open_synthesis:#{parent}",
          "parent_sample_index" => parent,
          "parent_output_sha256" => hash("parent-#{parent}"),
          "case_id" => "rag_open_synthesis",
          "split" => split,
          "label" => label,
          "failure_modes" => if(label == "subtle_regression", do: ["wrong_fact"], else: []),
          "expected_contract_pass" => label != "subtle_regression",
          "rationale" => "Approved synthetic judgment.",
          "output_text" => "#{label} variation #{word(parent)} value #{value} [transit]",
          "approval" => %{
            "status" => "approved",
            "reviewer" => "tester",
            "reviewed_at" => "2026-09-11T12:00:00Z"
          }
        }
      end

    {:ok, fixture_set} =
      PairedFixtureSet.new(%{
        fixture_set_id: "#{split}-fixtures-v1",
        created_at: fixed_clock(),
        git_revision: "abc123",
        status: "approved",
        source_control: %{
          "run_id" => source_run_id,
          "condition" => "control",
          "artifact_sha256" => hash(source_run_id),
          "case_id" => "rag_open_synthesis"
        },
        partition_policy: %{
          "version" => 1,
          "group_key" => "parent_observation_id",
          "splits" => ~w(authoring tuning heldout)
        },
        fixtures: fixtures,
        duplicate_counts: PairedFixtureSet.duplicate_counts(fixtures)
      })

    fixture_set
  end

  defp benchmark_options(role) do
    [
      evaluation_role: role,
      seeds: [7, 17],
      permutations: 199,
      adjusted_p_alpha: 0.05,
      harmless_review_rate_maximum: 0.10,
      subtle_review_rate_minimum: 1.0,
      multiple_comparison_family: "all_representation_batch_comparisons_per_seed",
      result_id: "benchmark-result",
      clock: &fixed_clock/0,
      git_revision: "abc123"
    ]
  end

  defp run(run_id, condition, outputs) do
    SpikeFixtures.analyzed_run(%{run_id: run_id, condition: condition, outputs: outputs})
  end

  defp outputs(prefix, value) do
    Enum.map(0..19, &"#{prefix} variation #{word(&1)} value #{value} [transit]")
  end

  defp word(index) do
    ~w(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen)
    |> Enum.at(index)
  end

  defp fixed_clock, do: ~U[2026-09-11 12:00:00Z]
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
