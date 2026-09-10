defmodule SilentRegression.Spike.SemanticLayer.ArtifactContractsTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.Calibration
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.SemanticLayer.RepresentationSpec
  alias SilentRegression.Spike.SemanticLayer.Storage

  test "all versioned contracts round-trip with JSON-compatible maps" do
    paired = paired_fixture_set()
    representation = representation_spec()
    calibration = calibration()
    result = benchmark_result()

    for {artifact, module} <- [
          {paired, PairedFixtureSet},
          {representation, RepresentationSpec},
          {calibration, Calibration},
          {result, BenchmarkResult}
        ] do
      encoded = module.to_map(artifact)
      assert encoded |> Map.keys() |> Enum.all?(&is_binary/1)
      assert {:ok, ^artifact} = module.from_map(encoded)
    end

    assert paired.duplicate_counts == [
             %{
               "split" => "heldout",
               "label" => "meaning_preserving",
               "sample_count" => 2,
               "unique_parent_count" => 2,
               "unique_output_count" => 2,
               "duplicate_output_count" => 0
             },
             %{
               "split" => "heldout",
               "label" => "style_only",
               "sample_count" => 2,
               "unique_parent_count" => 2,
               "unique_output_count" => 2,
               "duplicate_output_count" => 0
             },
             %{
               "split" => "heldout",
               "label" => "subtle_regression",
               "sample_count" => 2,
               "unique_parent_count" => 2,
               "unique_output_count" => 2,
               "duplicate_output_count" => 0
             }
           ]
  end

  test "calibration and representation contracts reject fixture-label leakage" do
    calibration_map = Calibration.to_map(calibration())

    with_fixture_ids = Map.put(calibration_map, "fixture_ids", ["approved-1"])

    assert {:error, %{field: :attributes, reason: :contains_unsupported_fields}} =
             Calibration.from_map(with_fixture_ids)

    with_fixture_source =
      put_in(
        calibration_map,
        ["source_runs", Access.at(1), "condition"],
        "approved_fixture"
      )

    assert {:error, %{field: :source_runs, reason: :must_contain_only_baseline_and_control_runs}} =
             Calibration.from_map(with_fixture_source)

    representation_map = RepresentationSpec.to_map(representation_spec())

    with_labels =
      put_in(representation_map, ["fit_policy", "fixture_labels_used"], true)

    assert {:error, %{field: :fit_policy, reason: :must_exclude_fixture_labels}} =
             RepresentationSpec.from_map(with_labels)

    with_fixture_fit =
      put_in(
        representation_map,
        ["fit_sources", Access.at(1), "condition"],
        "approved_fixture"
      )

    assert {:error, %{field: :fit_sources}} = RepresentationSpec.from_map(with_fixture_fit)
  end

  test "paired fixtures enforce parent partitions, approvals, and measured duplicates" do
    fixture_set_map = PairedFixtureSet.to_map(paired_fixture_set())

    cross_partition =
      put_in(fixture_set_map, ["fixtures", Access.at(1), "split"], "tuning")

    assert {:error, %{field: :fixtures, reason: :parent_observation_must_belong_to_one_split}} =
             PairedFixtureSet.from_map(cross_partition)

    unapproved =
      fixture_set_map
      |> put_in(["fixtures", Access.at(0), "approval"], candidate_approval())
      |> Map.put("duplicate_counts", fixture_set_map["duplicate_counts"])

    assert {:error, %{field: :fixtures, reason: :approved_set_requires_approved_fixtures}} =
             PairedFixtureSet.from_map(unapproved)

    false_counts =
      put_in(
        fixture_set_map,
        ["duplicate_counts", Access.at(0), "duplicate_output_count"],
        1
      )

    assert {:error, %{field: :duplicate_counts, reason: :must_match_fixture_outputs}} =
             PairedFixtureSet.from_map(false_counts)

    incomplete_fixtures =
      Enum.reject(fixture_set_map["fixtures"], &(&1["fixture_id"] == "fixture-2-regression"))

    incomplete_pairing =
      fixture_set_map
      |> Map.put("fixtures", incomplete_fixtures)
      |> Map.put("duplicate_counts", PairedFixtureSet.duplicate_counts(incomplete_fixtures))

    assert {:error, %{field: :fixtures, reason: :each_parent_must_have_required_labels}} =
             PairedFixtureSet.from_map(incomplete_pairing)

    inconsistent_parent =
      put_in(
        fixture_set_map,
        ["fixtures", Access.at(1), "parent_output_sha256"],
        hash("different-parent")
      )

    assert {:error,
            %{field: :fixtures, reason: :parent_observation_provenance_must_be_consistent}} =
             PairedFixtureSet.from_map(inconsistent_parent)
  end

  test "benchmark results keep method selection separate from final held-out evaluation" do
    result_map = BenchmarkResult.to_map(benchmark_result())

    tuning_in_final = put_in(result_map, ["batches", Access.at(0), "split"], "tuning")

    assert {:error, %{field: :batches, reason: :contains_invalid_or_leaky_batch}} =
             BenchmarkResult.from_map(tuning_in_final)

    cycled_parents =
      put_in(result_map, ["batches", Access.at(0), "unique_parent_count"], 1)

    assert {:error, %{field: :batches, reason: :contains_invalid_or_leaky_batch}} =
             BenchmarkResult.from_map(cycled_parents)

    changed_seed =
      put_in(
        result_map,
        [
          "batches",
          Access.at(0),
          "representation_results",
          Access.at(0),
          "seed_results",
          Access.at(1),
          "seed"
        ],
        999
      )

    assert {:error, %{field: :batches, reason: :contains_invalid_or_leaky_batch}} =
             BenchmarkResult.from_map(changed_seed)

    changed_method_version =
      put_in(
        result_map,
        ["batches", Access.at(0), "representation_results", Access.at(0), "method_version"],
        2
      )

    assert {:error, %{field: :batches, reason: :contains_invalid_or_leaky_batch}} =
             BenchmarkResult.from_map(changed_method_version)
  end

  @tag :tmp_dir
  test "semantic storage is immutable and refuses Task 11 artifact types", %{tmp_dir: tmp_dir} do
    artifacts = [
      paired_fixture_set(),
      representation_spec(),
      calibration(),
      benchmark_result()
    ]

    for {artifact, index} <- Enum.with_index(artifacts) do
      path = Path.join(tmp_dir, "artifact-#{index}.json")
      assert :ok = Storage.write(path, artifact)
      assert {:ok, ^artifact} = Storage.read(path)
      assert {:error, %{type: :already_exists}} = Storage.write(path, artifact)
    end

    task_11_path = Path.join(tmp_dir, "fixture-comparison.json")

    task_11_bytes =
      Jason.encode!(%{
        "schema_version" => 1,
        "artifact_type" => "fixture_comparison",
        "comparison_id" => "task-11"
      })

    File.write!(task_11_path, task_11_bytes)

    assert {:error, %{type: :unsupported_artifact_type}} = Storage.read(task_11_path)
    assert File.read!(task_11_path) == task_11_bytes
    assert {:error, %{type: :invalid_write}} = Storage.write(task_11_path, %{})
    assert File.read!(task_11_path) == task_11_bytes
  end

  defp paired_fixture_set do
    fixtures =
      for parent <- 1..2,
          {label, suffix} <- [
            {"meaning_preserving", "meaning"},
            {"style_only", "style"},
            {"subtle_regression", "regression"}
          ] do
        %{
          "fixture_id" => "fixture-#{parent}-#{suffix}",
          "parent_observation_id" => "heldout:rag_open_synthesis:#{parent}",
          "parent_sample_index" => parent - 1,
          "parent_output_sha256" => hash(<<parent>>),
          "case_id" => "rag_open_synthesis",
          "split" => "heldout",
          "label" => label,
          "output_text" => "Distinct #{suffix} derivative for parent #{parent}.",
          "approval" => approved_approval()
        }
      end

    {:ok, fixture_set} =
      PairedFixtureSet.new(%{
        fixture_set_id: "semantic-pairs-v1",
        created_at: ~U[2026-09-10 18:00:00Z],
        git_revision: "abc123",
        status: "approved",
        source_control: %{
          "run_id" => "heldout-control",
          "condition" => "control",
          "artifact_sha256" => hash("control"),
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

  defp representation_spec do
    {:ok, representation} =
      RepresentationSpec.new(%{
        representation_id: "word-bigram-v1",
        created_at: ~U[2026-09-10 18:05:00Z],
        git_revision: "abc123",
        method: %{
          "name" => "word_ngram",
          "version" => 1,
          "parameters" => %{"minimum_n" => 1, "maximum_n" => 2}
        },
        case_ids: ["rag_open_synthesis"],
        fit_sources: source_runs(),
        fit_observation_ids: ["baseline:0", "control:0"],
        fit_policy: %{
          "version" => 1,
          "fixture_labels_used" => false,
          "allowed_conditions" => ~w(baseline control)
        }
      })

    representation
  end

  defp calibration do
    {:ok, calibration} =
      Calibration.new(%{
        calibration_id: "semantic-calibration-v1",
        created_at: ~U[2026-09-10 18:10:00Z],
        git_revision: "abc123",
        status: "frozen",
        representation: %{
          "representation_id" => "word-bigram-v1",
          "artifact_sha256" => hash("representation"),
          "method_name" => "word_ngram",
          "method_version" => 1,
          "parameters_sha256" => hash("parameters")
        },
        case_ids: ["rag_open_synthesis"],
        source_runs: source_runs(),
        settings: %{
          "seed" => 20_260_910,
          "iterations" => 999,
          "quantile" => 0.95,
          "adjusted_p_alpha" => 0.05,
          "baseline_group_size" => 20,
          "control_group_size" => 20
        },
        thresholds: [
          %{
            "case_id" => "rag_open_synthesis",
            "threshold" => 0.2,
            "null_energies" => [0.0, 0.1, 0.2],
            "iterations" => 999,
            "baseline_size" => 20,
            "control_size" => 20,
            "empirical_exceedance_rate" => 0.05
          }
        ]
      })

    calibration
  end

  defp benchmark_result do
    {:ok, result} =
      BenchmarkResult.new(%{
        result_id: "semantic-benchmark-v1",
        created_at: ~U[2026-09-10 18:15:00Z],
        git_revision: "abc123",
        evaluation_role: "final_evaluation",
        fixture_set: %{
          "fixture_set_id" => "semantic-pairs-v1",
          "artifact_sha256" => hash("fixture-set"),
          "status" => "approved"
        },
        representations: [
          %{
            "representation_id" => "word-bigram-v1",
            "artifact_sha256" => hash("representation"),
            "method_name" => "word_ngram",
            "method_version" => 1
          }
        ],
        calibrations: [
          %{
            "calibration_id" => "semantic-calibration-v1",
            "artifact_sha256" => hash("calibration"),
            "representation_id" => "word-bigram-v1"
          }
        ],
        settings: %{"seeds" => [20_260_910, 20_260_911], "provider_calls" => 0},
        batches: [
          %{
            "batch_id" => "heldout-subtle",
            "case_id" => "rag_open_synthesis",
            "split" => "heldout",
            "label" => "subtle_regression",
            "sample_count" => 2,
            "unique_parent_count" => 2,
            "unique_output_count" => 2,
            "duplicate_output_count" => 0,
            "representation_results" => [
              %{
                "representation_id" => "word-bigram-v1",
                "method_version" => 1,
                "seed_results" => [
                  seed_result(20_260_910),
                  seed_result(20_260_911)
                ]
              }
            ]
          }
        ],
        summary: %{
          "heldout_case_comparisons" => 1,
          "drift_review_count" => 1,
          "drift_review_rate" => 1.0
        }
      })

    result
  end

  defp source_runs do
    [
      %{
        "run_id" => "baseline",
        "condition" => "baseline",
        "artifact_sha256" => hash("baseline")
      },
      %{
        "run_id" => "control",
        "condition" => "control",
        "artifact_sha256" => hash("control")
      }
    ]
  end

  defp seed_result(seed) do
    %{
      "seed" => seed,
      "energy_distance" => 0.3,
      "raw_p_value" => 0.01,
      "adjusted_p_value" => 0.04,
      "threshold" => 0.2,
      "outcome" => "drift_review"
    }
  end

  defp approved_approval do
    %{
      "status" => "approved",
      "reviewer" => "human-reviewer",
      "reviewed_at" => "2026-09-10T18:00:00Z"
    }
  end

  defp candidate_approval do
    %{"status" => "candidate", "reviewer" => nil, "reviewed_at" => nil}
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
