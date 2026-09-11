defmodule SilentRegression.Spike.SemanticLayer.RepresentationBenchmark do
  @moduledoc """
  Runs leakage-controlled batch comparisons for fitted local representations.

  Raw p-values are corrected as one family across every representation and
  semantic batch for each predeclared seed. Method selection is deterministic:
  eligible methods must pass the tuning gate, then the largest harmful-versus-
  harmless threshold margin wins, with input order as the final tie-breaker.
  """

  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.Calibration
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.SemanticLayer.Representation
  alias SilentRegression.Spike.SemanticLayer.RepresentationModel
  alias SilentRegression.Spike.SemanticLayer.RepresentationSpec
  alias SilentRegression.Spike.SemanticLayer.Storage
  alias SilentRegression.Spike.Statistics

  @allowed_options [
    :adjusted_p_alpha,
    :clock,
    :evaluation_role,
    :git_revision,
    :harmless_review_rate_maximum,
    :multiple_comparison_family,
    :permutations,
    :result_id,
    :seeds,
    :subtle_review_rate_minimum
  ]
  @labels ~w(meaning_preserving style_only subtle_regression)
  @harmless_labels ~w(meaning_preserving style_only)

  @type bundle :: %{
          required(:spec) => RepresentationSpec.t(),
          required(:spec_sha256) => String.t(),
          required(:model) => RepresentationModel.t(),
          required(:calibration) => Calibration.t(),
          required(:calibration_sha256) => String.t()
        }

  @spec run(Run.t(), PairedFixtureSet.t(), String.t(), [bundle()], keyword()) ::
          {:ok, BenchmarkResult.t()} | {:error, map()}
  def run(baseline, fixtures, fixture_sha256, bundles, options \\ [])

  def run(
        %Run{} = baseline,
        %PairedFixtureSet{} = fixtures,
        fixture_sha256,
        bundles,
        options
      )
      when is_list(bundles) and is_list(options) do
    with :ok <- validate_options(options),
         {:ok, role, expected_split} <- evaluation_role(options),
         {:ok, seeds} <- seeds(options),
         {:ok, permutations} <- positive_integer(options, :permutations, 999),
         {:ok, adjusted_p_alpha} <- probability(options, :adjusted_p_alpha, 0.05),
         {:ok, harmless_maximum} <-
           probability(options, :harmless_review_rate_maximum, 0.10),
         {:ok, subtle_minimum} <- probability(options, :subtle_review_rate_minimum, 1.0),
         {:ok, family} <- family(options),
         {:ok, created_at} <- timestamp(options),
         {:ok, git_revision} <- git_revision(options),
         :ok <- validate_fixture_set(fixtures, fixture_sha256, expected_split),
         :ok <- validate_bundles(baseline, fixtures, bundles, adjusted_p_alpha),
         {:ok, seed_comparisons} <-
           compare_all_seeds(
             baseline,
             fixtures,
             bundles,
             seeds,
             permutations,
             adjusted_p_alpha
           ),
         batches <- build_batches(fixtures, bundles, seeds, seed_comparisons),
         summary <-
           summarize(
             role,
             bundles,
             batches,
             harmless_maximum,
             subtle_minimum,
             family
           ),
         {:ok, result_id} <- result_id(role, created_at, options) do
      BenchmarkResult.new(%{
        result_id: result_id,
        created_at: created_at,
        git_revision: git_revision,
        evaluation_role: role,
        fixture_set: %{
          "fixture_set_id" => fixtures.fixture_set_id,
          "artifact_sha256" => fixture_sha256,
          "status" => fixtures.status
        },
        representations: Enum.map(bundles, &representation_reference/1),
        calibrations: Enum.map(bundles, &calibration_reference/1),
        settings: %{
          "seeds" => seeds,
          "permutations" => permutations,
          "adjusted_p_alpha" => adjusted_p_alpha,
          "multiple_comparison_family" => family,
          "provider_calls" => 0
        },
        batches: batches,
        summary: summary
      })
    end
  end

  def run(_baseline, _fixtures, _fixture_sha256, _bundles, _options),
    do: error(:invalid_benchmark_input)

  defp validate_options(options) do
    keys = Keyword.keys(options)

    cond do
      not Keyword.keyword?(options) ->
        error(:options_must_be_a_keyword_list)

      Enum.uniq(keys) != keys ->
        error(:options_must_be_unique)

      keys -- @allowed_options != [] ->
        error(:unsupported_options, options: keys -- @allowed_options)

      true ->
        :ok
    end
  end

  defp evaluation_role(options) do
    case Keyword.get(options, :evaluation_role) do
      "method_selection" -> {:ok, "method_selection", "tuning"}
      "final_evaluation" -> {:ok, "final_evaluation", "heldout"}
      _role -> error(:unsupported_evaluation_role)
    end
  end

  defp seeds(options) do
    seeds = Keyword.get(options, :seeds)

    if is_list(seeds) and seeds != [] and Enum.all?(seeds, &(is_integer(&1) and &1 >= 0)) and
         Enum.uniq(seeds) == seeds,
       do: {:ok, seeds},
       else: error(:seeds_must_be_unique_non_negative_integers)
  end

  defp positive_integer(options, name, default) do
    value = Keyword.get(options, name, default)
    if is_integer(value) and value > 0, do: {:ok, value}, else: error(:invalid_positive_integer)
  end

  defp probability(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_number(value) and value >= 0 and value <= 1,
      do: {:ok, value * 1.0},
      else: error(:invalid_probability)
  end

  defp family(options) do
    value = Keyword.get(options, :multiple_comparison_family)

    if value == "all_representation_batch_comparisons_per_seed",
      do: {:ok, value},
      else: error(:unsupported_multiple_comparison_family)
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp -> {:ok, timestamp}
      _value -> error(:clock_must_return_datetime)
    end
  rescue
    exception -> error(:clock_raised, exception: inspect(exception.__struct__))
  end

  defp git_revision(options) do
    value = Keyword.get(options, :git_revision)

    if is_nil(value) or (is_binary(value) and String.trim(value) != ""),
      do: {:ok, value},
      else: error(:git_revision_must_be_a_string)
  end

  defp result_id(role, created_at, options) do
    value =
      Keyword.get_lazy(options, :result_id, fn ->
        timestamp = Calendar.strftime(created_at, "%Y%m%dT%H%M%SZ")
        "semantic-benchmark-#{role}-#{timestamp}"
      end)

    if is_binary(value) and String.trim(value) != "",
      do: {:ok, value},
      else: error(:result_id_must_be_a_string)
  end

  defp validate_fixture_set(fixtures, fixture_sha256, expected_split) do
    splits = fixtures.fixtures |> Enum.map(& &1["split"]) |> Enum.uniq()
    labels = fixtures.fixtures |> Enum.map(& &1["label"]) |> Enum.uniq()

    cond do
      fixtures.status != "approved" -> error(:fixture_set_must_be_approved)
      not sha256?(fixture_sha256) -> error(:fixture_sha256_is_invalid)
      splits != [expected_split] -> error(:fixture_split_does_not_match_evaluation_role)
      not Enum.all?(@labels, &(&1 in labels)) -> error(:required_batches_are_missing)
      true -> :ok
    end
  end

  defp validate_bundles(baseline, fixtures, bundles, adjusted_p_alpha) do
    cond do
      bundles == [] ->
        error(:at_least_one_representation_required)

      not Enum.all?(bundles, &valid_bundle_shape?/1) ->
        error(:invalid_representation_bundle)

      bundles |> Enum.map(& &1.spec.representation_id) |> Enum.uniq() |> length() !=
          length(bundles) ->
        error(:representation_ids_must_be_unique)

      true ->
        Enum.reduce_while(bundles, :ok, fn bundle, :ok ->
          case validate_bundle(baseline, fixtures, bundle, adjusted_p_alpha) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
    end
  end

  defp valid_bundle_shape?(bundle) do
    match?(
      %{
        spec: %RepresentationSpec{},
        spec_sha256: spec_sha256,
        model: %RepresentationModel{},
        calibration: %Calibration{},
        calibration_sha256: calibration_sha256
      }
      when is_binary(spec_sha256) and is_binary(calibration_sha256),
      bundle
    )
  end

  defp validate_bundle(baseline, fixtures, bundle, adjusted_p_alpha) do
    calibration = bundle.calibration
    spec = bundle.spec
    case_id = fixtures.source_control["case_id"]
    source_run_ids = Enum.map(calibration.source_runs, & &1["run_id"])

    with {:ok, actual_spec_sha256} <- Storage.sha256(spec),
         {:ok, actual_calibration_sha256} <- Storage.sha256(calibration) do
      cond do
        bundle.spec_sha256 != actual_spec_sha256 or
            bundle.calibration_sha256 != actual_calibration_sha256 ->
          error(:artifact_hash_mismatch)

        spec.representation_id != calibration.representation["representation_id"] ->
          error(:calibration_representation_mismatch)

        bundle.spec_sha256 != calibration.representation["artifact_sha256"] ->
          error(:calibration_representation_hash_mismatch)

        spec.method["name"] != bundle.model.method_name or
          spec.method["version"] != bundle.model.method_version or
            spec.method["parameters"] != bundle.model.parameters ->
          error(:fitted_model_mismatch)

        spec.case_ids != [case_id] or calibration.case_ids != [case_id] ->
          error(:benchmark_case_mismatch)

        baseline.run_id not in source_run_ids ->
          error(:baseline_missing_from_calibration)

        fixtures.source_control["run_id"] in source_run_ids ->
          error(:fixture_parent_run_leaked_into_calibration)

        calibration.settings["adjusted_p_alpha"] != adjusted_p_alpha ->
          error(:adjusted_p_alpha_mismatch)

        calibration.settings["baseline_group_size"] !=
            length(Comparison.completed_outputs(baseline, case_id)) ->
          error(:baseline_sample_size_mismatch)

        calibration.settings["control_group_size"] != batch_size(fixtures) ->
          error(:candidate_sample_size_mismatch)

        true ->
          :ok
      end
    end
  end

  defp compare_all_seeds(
         baseline,
         fixtures,
         bundles,
         seeds,
         permutations,
         adjusted_p_alpha
       ) do
    case_id = fixtures.source_control["case_id"]
    reference = Comparison.completed_outputs(baseline, case_id)
    batches = fixture_batches(fixtures)

    seeds
    |> Enum.reduce_while({:ok, []}, fn seed, {:ok, accumulated} ->
      with {:ok, comparisons} <-
             compare_seed(reference, batches, bundles, seed, permutations),
           {:ok, adjusted} <-
             Statistics.benjamini_hochberg(Enum.map(comparisons, & &1.raw_p_value)) do
        corrected =
          comparisons
          |> Enum.zip(adjusted)
          |> Enum.map(fn {comparison, adjusted_p_value} ->
            threshold = threshold(comparison.bundle)

            outcome =
              if comparison.energy_distance > threshold and
                   adjusted_p_value <= adjusted_p_alpha,
                 do: "drift_review",
                 else: "no_drift_review"

            %{
              seed: seed,
              label: comparison.label,
              representation_id: comparison.bundle.spec.representation_id,
              result: %{
                "seed" => seed,
                "energy_distance" => comparison.energy_distance,
                "raw_p_value" => comparison.raw_p_value,
                "adjusted_p_value" => adjusted_p_value,
                "threshold" => threshold,
                "outcome" => outcome
              }
            }
          end)

        {:cont, {:ok, accumulated ++ corrected}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp compare_seed(reference, batches, bundles, seed, permutations) do
    for {label, fixtures} <- batches,
        bundle <- bundles,
        reduce: {:ok, []} do
      {:ok, results} ->
        samples = Enum.map(fixtures, & &1["output_text"])

        options =
          Representation.statistics_options(bundle.model) ++
            [seed: seed, permutations: permutations]

        case Statistics.permutation_test(reference, samples, options) do
          {:ok, result} ->
            comparison = %{
              label: label,
              bundle: bundle,
              energy_distance: result["observed_energy"],
              raw_p_value: result["p_value"]
            }

            {:ok, results ++ [comparison]}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_batches(fixtures, bundles, seeds, comparisons) do
    fixtures
    |> fixture_batches()
    |> Enum.map(fn {label, batch_fixtures} ->
      sample_count = length(batch_fixtures)

      unique_output_count =
        batch_fixtures |> Enum.map(& &1["output_text"]) |> Enum.uniq() |> length()

      %{
        "batch_id" => "#{hd(batch_fixtures)["split"]}-#{label}",
        "case_id" => hd(batch_fixtures)["case_id"],
        "split" => hd(batch_fixtures)["split"],
        "label" => label,
        "sample_count" => sample_count,
        "unique_parent_count" =>
          batch_fixtures |> Enum.map(& &1["parent_observation_id"]) |> Enum.uniq() |> length(),
        "unique_output_count" => unique_output_count,
        "duplicate_output_count" => sample_count - unique_output_count,
        "representation_results" =>
          Enum.map(bundles, fn bundle ->
            %{
              "representation_id" => bundle.spec.representation_id,
              "method_version" => bundle.spec.method["version"],
              "seed_results" =>
                Enum.map(seeds, fn seed ->
                  comparisons
                  |> Enum.find(
                    &(&1.seed == seed and &1.label == label and
                        &1.representation_id == bundle.spec.representation_id)
                  )
                  |> Map.fetch!(:result)
                end)
            }
          end)
      }
    end)
  end

  defp summarize(role, bundles, batches, harmless_maximum, subtle_minimum, family) do
    by_representation =
      Enum.map(bundles, fn bundle ->
        results = representation_results(batches, bundle.spec.representation_id)
        harmless = Enum.filter(results, &(&1.label in @harmless_labels))
        subtle = Enum.filter(results, &(&1.label == "subtle_regression"))
        harmless_reviews = Enum.count(harmless, &(&1.outcome == "drift_review"))
        subtle_reviews = Enum.count(subtle, &(&1.outcome == "drift_review"))
        harmless_rate = harmless_reviews / length(harmless)
        subtle_rate = subtle_reviews / length(subtle)
        stable = stable_across_seeds?(results)

        %{
          "representation_id" => bundle.spec.representation_id,
          "method_name" => bundle.spec.method["name"],
          "harmless_comparison_count" => length(harmless),
          "harmless_drift_review_count" => harmless_reviews,
          "harmless_drift_review_rate" => harmless_rate,
          "subtle_comparison_count" => length(subtle),
          "subtle_drift_review_count" => subtle_reviews,
          "subtle_drift_review_rate" => subtle_rate,
          "stable_across_seeds" => stable,
          "separation_margin" => separation_margin(harmless, subtle),
          "passes_gate" =>
            harmless_rate <= harmless_maximum and subtle_rate >= subtle_minimum and stable
        }
      end)

    selected =
      by_representation
      |> Enum.with_index()
      |> Enum.filter(fn {result, _index} -> result["passes_gate"] end)
      |> Enum.sort_by(fn {result, index} -> {-result["separation_margin"], index} end)
      |> Enum.take(1)
      |> Enum.map(fn {result, _index} -> result["representation_id"] end)

    %{
      "evaluation_role" => role,
      "multiple_comparison_family" => family,
      "selection_policy" => %{
        "version" => 1,
        "harmless_review_rate_maximum" => harmless_maximum,
        "subtle_review_rate_minimum" => subtle_minimum,
        "require_seed_stability" => true,
        "winner_rule" => "largest_separation_margin_then_predeclared_order"
      },
      "by_representation" => by_representation,
      "selected_representation_ids" => selected,
      "gate_status" => if(selected == [], do: "failed", else: "passed")
    }
  end

  defp representation_results(batches, representation_id) do
    Enum.flat_map(batches, fn batch ->
      representation =
        Enum.find(
          batch["representation_results"],
          &(&1["representation_id"] == representation_id)
        )

      Enum.map(representation["seed_results"], fn result ->
        %{
          label: batch["label"],
          outcome: result["outcome"],
          margin: result["energy_distance"] - result["threshold"]
        }
      end)
    end)
  end

  defp stable_across_seeds?(results) do
    results
    |> Enum.group_by(& &1.label, & &1.outcome)
    |> Enum.all?(fn {_label, outcomes} -> length(Enum.uniq(outcomes)) == 1 end)
  end

  defp separation_margin(harmless, subtle) do
    subtle_margin = Enum.min_by(subtle, & &1.margin).margin
    harmless_margin = Enum.max_by(harmless, & &1.margin).margin
    subtle_margin - harmless_margin
  end

  defp fixture_batches(fixtures) do
    Enum.map(@labels, fn label ->
      {label, Enum.filter(fixtures.fixtures, &(&1["label"] == label))}
    end)
  end

  defp batch_size(fixtures) do
    Enum.count(fixtures.fixtures, &(&1["label"] == hd(@labels)))
  end

  defp threshold(bundle), do: hd(bundle.calibration.thresholds)["threshold"]

  defp representation_reference(bundle) do
    %{
      "representation_id" => bundle.spec.representation_id,
      "artifact_sha256" => bundle.spec_sha256,
      "method_name" => bundle.spec.method["name"],
      "method_version" => bundle.spec.method["version"]
    }
  end

  defp calibration_reference(bundle) do
    %{
      "calibration_id" => bundle.calibration.calibration_id,
      "artifact_sha256" => bundle.calibration_sha256,
      "representation_id" => bundle.spec.representation_id
    }
  end

  defp sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp error(reason, details \\ []), do: {:error, Map.new([{:type, reason} | details])}
end
