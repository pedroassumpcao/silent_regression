defmodule SilentRegression.Spike.SemanticLayer.DecisionReportTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.ContractRescoreResult
  alias SilentRegression.Spike.SemanticLayer.DecisionReport
  alias SilentRegression.SpikeFixtures

  test "keeps evidence denominators separate and leaves the human decision pending" do
    manifest = manifest()
    evidence = evidence()

    assert {:ok, report} =
             DecisionReport.build_from_evidence(manifest, evidence, clock: &fixed_clock/0)

    assert report["recommendation"] == "DETERMINISTIC_ONLY_WEDGE"
    assert report["human_decision"] == "PENDING_HUMAN_DECISION"
    assert report["provider_calls"] == 0

    deterministic = report["deterministic_contracts"]
    assert deterministic["matched_expectation_count"] == 8
    assert deterministic["fixture_count"] == 8
    assert deterministic["false_failure_count"] == 0
    assert deterministic["missed_regression_count"] == 0

    lexical = report["lexical_distribution"]
    assert lexical["false_review_count"] == 1
    assert lexical["harmless_case_comparison_count"] == 2

    assert lexical["batches"]
           |> Enum.find(&(&1["batch_id"] == "mixed_regression_10"))
           |> Map.take(
             ~w(case_comparison_count drift_review_count deterministic_regression_count any_signal_count)
           ) == %{
             "case_comparison_count" => 2,
             "drift_review_count" => 0,
             "deterministic_regression_count" => 1,
             "any_signal_count" => 1
           }

    semantic = report["cheap_semantic"]
    assert semantic["heldout_harmless_review_count"] == 1
    assert semantic["heldout_harmless_comparison_count"] == 4
    assert semantic["heldout_subtle_review_count"] == 2
    assert semantic["heldout_subtle_comparison_count"] == 2

    assert report["markdown"] =~ "These units are deliberately not pooled"
    assert report["markdown"] =~ "Historical dollar cost is **not computable**"
    assert report["markdown"] =~ "Permutation seeds measure statistical-decision stability"
    assert report["markdown"] =~ "rag_case"
  end

  test "records an approved decision separately from the evidence recommendation" do
    assert {:ok, report} =
             DecisionReport.build_from_evidence(manifest(), evidence(),
               decision: "EVALUATE_MODEL_BASED_SEMANTICS",
               clock: &fixed_clock/0
             )

    assert report["recommendation"] == "DETERMINISTIC_ONLY_WEDGE"
    assert report["human_decision"] == "EVALUATE_MODEL_BASED_SEMANTICS"

    assert {:error, %{type: :unsupported_decision}} =
             DecisionReport.build_from_evidence(manifest(), evidence(),
               decision: "SHIP_EVERYTHING"
             )
  end

  @tag :tmp_dir
  test "refuses to overwrite an immutable report", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "decision.md")

    assert :ok = DecisionReport.write(path, "first\n")
    assert {:error, %{type: :already_exists}} = DecisionReport.write(path, "second\n")
    assert File.read!(path) == "first\n"
  end

  defp manifest do
    %{
      "schema_version" => 1,
      "report_id" => "decision-report-test",
      "live_runs" => [
        reference("baseline", "baseline", "baseline.json"),
        reference("control", "heldout_control", "control.json")
      ],
      "fixture_comparison" => reference("fixture", nil, "fixture.json"),
      "contract_rescore" => reference("contract", nil, "contract.json"),
      "semantic_tuning" => reference("tuning", nil, "tuning.json"),
      "semantic_heldout" => reference("heldout", nil, "heldout.json")
    }
  end

  defp reference(id, role, path) do
    reference = %{
      "artifact_id" => id,
      "path" => path,
      "artifact_sha256" => hash(id)
    }

    if role, do: Map.put(reference, "role", role), else: reference
  end

  defp evidence do
    baseline =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "baseline",
        condition: "baseline",
        sample_size: 1
      })

    control =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: "control",
        condition: "control",
        sample_size: 1
      })

    %{
      live_runs: [baseline, control],
      fixture_comparison: fixture_comparison(),
      contract_rescore: contract_rescore(),
      semantic_tuning: benchmark("method_selection", "passed", 0, 4, 2, 2),
      semantic_heldout: benchmark("final_evaluation", "failed", 1, 4, 2, 2)
    }
  end

  defp fixture_comparison do
    %{
      "baseline_run_id" => "baseline",
      "control_run_id" => "control",
      "provider_calls" => 0,
      "reference_control" => %{
        "comparison" => %{
          "by_case" => [
            comparison(
              "rag_case",
              "no_drift_review",
              "no_deterministic_regression",
              "no_alert"
            ),
            comparison(
              "other_case",
              "no_drift_review",
              "no_deterministic_regression",
              "no_alert"
            )
          ]
        }
      },
      "summary" => %{"decision_gate" => %{"status" => "needs_semantic_layer"}},
      "batches" => [
        %{
          "batch_id" => "harmless_rewording",
          "intended_label" => "acceptable",
          "expected_regression_rate" => 0.0,
          "comparison" => %{
            "by_case" => [
              comparison(
                "rag_case",
                "drift_review",
                "no_deterministic_regression",
                "drift_review"
              ),
              comparison(
                "other_case",
                "no_drift_review",
                "no_deterministic_regression",
                "no_alert"
              )
            ]
          }
        },
        %{
          "batch_id" => "mixed_regression_10",
          "intended_label" => "regression",
          "expected_regression_rate" => 0.1,
          "comparison" => %{
            "by_case" => [
              comparison(
                "rag_case",
                "no_drift_review",
                "deterministic_regression",
                "deterministic_regression"
              ),
              comparison(
                "other_case",
                "no_drift_review",
                "no_deterministic_regression",
                "no_alert"
              )
            ]
          }
        }
      ]
    }
  end

  defp comparison(case_id, drift, deterministic, alert) do
    %{
      "case_id" => case_id,
      "drift_outcome" => drift,
      "deterministic_outcome" => deterministic,
      "alert_outcome" => alert
    }
  end

  defp contract_rescore do
    struct(ContractRescoreResult,
      evaluation_id: "contract",
      provider_calls: 0,
      summary: %{
        "fixture_count" => 8,
        "matched_expectation_count" => 8,
        "expected_pass_count" => 5,
        "expected_pass_matched_count" => 5,
        "expected_fail_count" => 3,
        "expected_fail_matched_count" => 3,
        "by_split" => [
          %{
            "split" => "heldout",
            "fixture_count" => 8,
            "expected_pass_count" => 5,
            "expected_pass_matched_count" => 5,
            "expected_fail_count" => 3,
            "expected_fail_matched_count" => 3,
            "matched_expectation_count" => 8
          }
        ],
        "by_case" => [
          %{
            "case_id" => "rag_case",
            "fixture_count" => 8,
            "expected_pass_count" => 5,
            "expected_pass_matched_count" => 5,
            "expected_fail_count" => 3,
            "expected_fail_matched_count" => 3,
            "matched_expectation_count" => 8
          }
        ],
        "by_failure_mode" => [
          %{"failure_mode" => "wrong_fact", "detected_count" => 3, "fixture_count" => 3}
        ]
      }
    )
  end

  defp benchmark(role, gate, harmless_reviews, harmless_count, subtle_reviews, subtle_count) do
    struct(BenchmarkResult,
      result_id: if(role == "method_selection", do: "tuning", else: "heldout"),
      evaluation_role: role,
      representations: [
        %{
          "representation_id" => "field-aware-v2",
          "method_name" => "field_aware",
          "method_version" => 2,
          "artifact_sha256" => hash("representation")
        }
      ],
      settings: %{"provider_calls" => 0},
      batches: semantic_batches(role),
      summary: %{
        "gate_status" => gate,
        "selected_representation_ids" => ["field-aware-v2"],
        "by_representation" => [
          %{
            "harmless_drift_review_count" => harmless_reviews,
            "harmless_comparison_count" => harmless_count,
            "harmless_drift_review_rate" => harmless_reviews / harmless_count,
            "subtle_drift_review_count" => subtle_reviews,
            "subtle_comparison_count" => subtle_count,
            "stable_across_seeds" => true
          }
        ]
      }
    )
  end

  defp semantic_batches(role) do
    split = if role == "method_selection", do: "tuning", else: "heldout"

    [
      semantic_batch(split, "meaning_preserving", ["drift_review", "no_drift_review"]),
      semantic_batch(split, "style_only", ["no_drift_review", "no_drift_review"]),
      semantic_batch(split, "subtle_regression", ["drift_review", "drift_review"])
    ]
  end

  defp semantic_batch(split, label, outcomes) do
    %{
      "batch_id" => "#{split}-#{label}",
      "case_id" => "rag_case",
      "label" => label,
      "unique_parent_count" => 20,
      "representation_results" => [
        %{
          "seed_results" =>
            Enum.map(outcomes, fn outcome ->
              %{"outcome" => outcome, "energy_distance" => 0.2, "threshold" => 0.03}
            end)
        }
      ]
    }
  end

  defp fixed_clock, do: ~U[2026-09-11 16:00:00Z]
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
