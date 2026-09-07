defmodule SilentRegression.Spike.StatisticsTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Statistics

  describe "distance collections" do
    test "returns hand-computed distinct within distances in stable order" do
      assert {:ok, distances} = Statistics.within_distances(["a", "a b", "b"])

      assert length(distances) == 3
      assert_in_delta Enum.at(distances, 0), 0.5, 1.0e-12
      assert_in_delta Enum.at(distances, 1), 1.0, 1.0e-12
      assert_in_delta Enum.at(distances, 2), 0.5, 1.0e-12
    end

    test "returns every hand-computed cross distance in stable order" do
      assert {:ok, distances} =
               Statistics.cross_distances(["a", "b"], ["a b", "c"])

      assert distances == [0.5, 1.0, 0.5, 1.0]
    end

    test "reports insufficient and invalid samples explicitly" do
      assert {:error,
              %{
                type: :insufficient_data,
                operation: :within_distances,
                minimum_count: 2,
                actual_count: 1
              }} = Statistics.within_distances(["only one"])

      assert {:error,
              %{
                type: :insufficient_data,
                operation: :cross_distances,
                group: :candidate,
                actual_count: 0
              }} = Statistics.cross_distances(["reference"], [])

      assert {:error,
              %{
                type: :invalid_sample,
                operation: :within_distances,
                sample_index: 1
              }} = Statistics.within_distances(["valid", nil])
    end
  end

  describe "energy_distance/2" do
    test "matches a fully separated hand-computed example" do
      assert {:ok, result} = Statistics.energy_distance(["red", "red"], ["blue", "blue"])

      assert result["within_reference_mean"] == 0.0
      assert result["within_candidate_mean"] == 0.0
      assert result["cross_mean"] == 1.0
      assert result["energy_distance"] == 2.0
      assert result["within_reference_pair_count"] == 1
      assert result["within_candidate_pair_count"] == 1
      assert result["cross_pair_count"] == 4
    end

    test "is symmetric across groups" do
      reference = ["red ferry", "red electric ferry", "electric ferry"]
      candidate = ["blue harbor", "blue quiet harbor"]

      assert {:ok, forward} = Statistics.energy_distance(reference, candidate)
      assert {:ok, reverse} = Statistics.energy_distance(candidate, reference)

      assert_in_delta forward["energy_distance"], reverse["energy_distance"], 1.0e-12
      assert_in_delta forward["cross_mean"], reverse["cross_mean"], 1.0e-12
    end

    test "is zero for identical constant distributions" do
      assert {:ok, result} =
               Statistics.energy_distance(["same", "same", "same"], ["same", "same"])

      assert result["energy_distance"] == 0.0
    end

    test "does not clamp a negative finite-sample estimate" do
      assert {:ok, result} = Statistics.energy_distance(["red", "blue"], ["red", "blue"])

      assert result["energy_distance"] == -1.0
    end

    test "requires two samples in each group" do
      assert {:error,
              %{
                type: :insufficient_data,
                operation: :energy_distance,
                group: :candidate,
                minimum_count: 2,
                actual_count: 1
              }} = Statistics.energy_distance(["a", "b"], ["c"])
    end
  end

  describe "permutation_test/3" do
    test "is deterministic for the same seed and preserves observed components" do
      reference = ["red apple", "apple red", "red apple red", "red, apple"]
      candidate = ["blue sky", "sky blue", "blue sky blue", "blue, sky"]
      options = [seed: 417, permutations: 499]

      assert {:ok, first} = Statistics.permutation_test(reference, candidate, options)
      assert {:ok, second} = Statistics.permutation_test(reference, candidate, options)

      assert first == second
      assert first["observed_energy"] == 2.0
      assert first["p_value"] >= 1 / 500
      assert first["p_value"] < 0.1
      assert first["permutations"] == 499
      assert is_binary(Jason.encode!(first))
    end

    test "returns p=1 for identical constant distributions" do
      assert {:ok, result} =
               Statistics.permutation_test(
                 ["same", "same", "same"],
                 ["same", "same", "same"],
                 seed: 9,
                 permutations: 49
               )

      assert result["observed_energy"] == 0.0
      assert result["p_value"] == 1.0
      assert result["extreme_permutations"] == 49
    end

    test "requires an explicit integer seed and positive permutation count" do
      assert {:error, %{type: :invalid_option, option: :seed, reason: :required}} =
               Statistics.permutation_test(["a", "b"], ["c", "d"])

      assert {:error, %{type: :invalid_option, option: :seed, reason: :must_be_an_integer}} =
               Statistics.permutation_test(["a", "b"], ["c", "d"], seed: "9")

      assert {:error,
              %{type: :invalid_option, option: :permutations, reason: :must_be_a_positive_integer}} =
               Statistics.permutation_test(["a", "b"], ["c", "d"],
                 seed: 9,
                 permutations: 0
               )
    end
  end

  describe "null calibration" do
    test "resampling and threshold calibration repeat exactly for a seed" do
      options = [seed: 82, iterations: 40, reference_size: 4, candidate_size: 4]

      assert {:ok, first_distribution} = Statistics.null_distribution(null_batches(), options)
      assert {:ok, second_distribution} = Statistics.null_distribution(null_batches(), options)
      assert first_distribution == second_distribution
      assert length(first_distribution["energies"]) == 40
      assert first_distribution["source_conditions"] == ["baseline", "control"]
      assert first_distribution["source_counts"] == %{"baseline" => 4, "control" => 4}

      assert {:ok, first_calibration} =
               Statistics.calibrate_threshold(null_batches(), options ++ [quantile: 0.8])

      assert {:ok, second_calibration} =
               Statistics.calibrate_threshold(null_batches(), options ++ [quantile: 0.8])

      assert first_calibration == second_calibration

      sorted_energies = Enum.sort(first_calibration["null_energies"])
      expected_threshold = Enum.at(sorted_energies, ceil(0.8 * 40) - 1)

      assert first_calibration["threshold"] == expected_threshold
      assert first_calibration["quantile"] == 0.8
      assert is_binary(Jason.encode!(first_calibration))
    end

    test "refuses every non-null condition before threshold construction" do
      for condition <- [
            "subtle_regression",
            "mixed_regression",
            "obvious_regression",
            "harmless_rewording"
          ] do
        batches =
          null_batches() ++
            [%{"condition" => condition, "samples" => ["fixture one", "fixture two"]}]

        assert {:error,
                %{
                  type: :invalid_calibration_input,
                  reason: :non_null_condition,
                  condition: ^condition
                }} = Statistics.calibrate_threshold(batches, seed: 17, iterations: 20)
      end
    end

    test "reports insufficient pooled and requested sample sizes" do
      assert {:error, %{type: :insufficient_data, operation: :null_distribution}} =
               Statistics.null_distribution([], seed: 1)

      assert {:error,
              %{
                type: :insufficient_data,
                operation: :null_distribution,
                available_samples: 8,
                requested_samples: 9
              }} =
               Statistics.null_distribution(null_batches(),
                 seed: 1,
                 reference_size: 5,
                 candidate_size: 4
               )
    end

    test "requires an explicit seed and a valid empirical quantile" do
      assert {:error, %{type: :invalid_option, option: :seed, reason: :required}} =
               Statistics.null_distribution(null_batches())

      assert {:error, %{type: :invalid_option, option: :quantile}} =
               Statistics.calibrate_threshold(null_batches(), seed: 1, quantile: 1.1)
    end
  end

  describe "benjamini_hochberg/1" do
    test "matches a hand-computed example and restores original order" do
      assert {:ok, adjusted} = Statistics.benjamini_hochberg([0.01, 0.04, 0.03, 0.002])

      expected = [0.02, 0.04, 0.04, 0.008]

      adjusted
      |> Enum.zip(expected)
      |> Enum.each(fn {actual, expected_value} ->
        assert_in_delta actual, expected_value, 1.0e-12
      end)
    end

    test "is monotone in ranked order and caps adjusted values at one" do
      p_values = [0.8, 0.01, 0.5, 1.0, 0.2]
      assert {:ok, adjusted} = Statistics.benjamini_hochberg(p_values)

      ranked =
        p_values
        |> Enum.zip(adjusted)
        |> Enum.sort_by(fn {raw, _adjusted} -> raw end)

      ranked_adjusted = Enum.map(ranked, fn {_raw, adjusted_value} -> adjusted_value end)

      assert ranked_adjusted == Enum.sort(ranked_adjusted)
      assert Enum.all?(adjusted, &(&1 >= 0.0 and &1 <= 1.0))
    end

    test "rejects empty, non-list, and out-of-range inputs" do
      assert {:error, %{type: :insufficient_data}} = Statistics.benjamini_hochberg([])
      assert {:error, %{type: :invalid_p_values}} = Statistics.benjamini_hochberg(nil)

      assert {:error, %{type: :invalid_p_values, reason: :outside_unit_interval}} =
               Statistics.benjamini_hochberg([0.1, 1.01])
    end
  end

  describe "descriptive helpers" do
    test "uses sample standard deviation rather than population deviation" do
      values = [2, 4, 4, 4, 5, 5, 7, 9]

      assert {:ok, standard_deviation} = Statistics.sample_standard_deviation(values)
      assert_in_delta standard_deviation, :math.sqrt(32 / 7), 1.0e-12

      assert {:ok, summary} = Statistics.summarize(values)
      assert summary["count"] == 8
      assert summary["mean"] == 5.0
      assert summary["sample_standard_deviation"] == standard_deviation
      assert summary["minimum"] == 2
      assert summary["maximum"] == 9
    end

    test "does not return misleading zeros for undersized inputs" do
      assert {:error, %{type: :insufficient_data, operation: :mean}} = Statistics.mean([])

      assert {:error,
              %{
                type: :insufficient_data,
                operation: :sample_standard_deviation,
                minimum_count: 2,
                actual_count: 1
              }} = Statistics.sample_standard_deviation([4])

      assert {:error, %{type: :insufficient_data}} = Statistics.summarize([4])
    end
  end

  defp null_batches do
    [
      %{
        "condition" => "baseline",
        "samples" => ["red apple", "red fruit", "apple fruit", "red berry"]
      },
      %{
        "condition" => "control",
        "samples" => ["apple red", "fruit red", "fruit apple", "berry red"]
      }
    ]
  end
end
