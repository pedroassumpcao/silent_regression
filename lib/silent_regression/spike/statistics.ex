defmodule SilentRegression.Spike.Statistics do
  @moduledoc """
  Dependency-free statistics for the spike's lexical drift layer.

  Energy distance is estimated from distinct within-group pairs and every
  cross-group pair. The finite-sample estimate is intentionally not clamped, so
  it may be slightly negative. Randomized operations use local `:rand` state
  derived from an explicit integer seed and do not alter process-global RNG
  state.

  Null calibration accepts only batches labeled `baseline` or `control`. This
  boundary prevents regression and rewording fixtures from influencing the
  pre-calibrated review threshold.
  """

  alias SilentRegression.Spike.Lexical

  @null_conditions ["baseline", "control"]

  @type error :: %{required(:type) => atom(), optional(atom()) => term()}
  @type result :: %{required(String.t()) => term()}

  @doc """
  Returns all distinct unordered within-sample Jaccard distances.
  """
  @spec within_distances(term()) :: {:ok, [float()]} | {:error, error()}
  def within_distances(samples, options \\ []) do
    with :ok <- require_sample_count(samples, 2, :within_distances),
         {:ok, normalizer, distance} <- metric(options, :within_distances),
         {:ok, sets} <- normalize_samples(samples, :within_distances, normalizer) do
      {:ok, within_set_distances(sets, distance)}
    end
  end

  @doc """
  Returns every reference-to-candidate Jaccard distance in stable order.
  """
  @spec cross_distances(term(), term()) :: {:ok, [float()]} | {:error, error()}
  def cross_distances(reference_samples, candidate_samples, options \\ []) do
    with :ok <- require_sample_count(reference_samples, 1, :cross_distances, :reference),
         :ok <- require_sample_count(candidate_samples, 1, :cross_distances, :candidate),
         {:ok, normalizer, distance} <- metric(options, :cross_distances),
         {:ok, reference_sets} <-
           normalize_samples(reference_samples, :cross_distances, normalizer),
         {:ok, candidate_sets} <-
           normalize_samples(candidate_samples, :cross_distances, normalizer) do
      {:ok, cross_set_distances(reference_sets, candidate_sets, distance)}
    end
  end

  @doc """
  Computes within, cross, and lexical energy-distance components.

  Each group needs two successful samples because within-group means use
  distinct pairs.
  """
  @spec energy_distance(term(), term()) :: {:ok, result()} | {:error, error()}
  def energy_distance(reference_samples, candidate_samples, options \\ []) do
    with :ok <- require_energy_samples(reference_samples, candidate_samples, :energy_distance),
         {:ok, normalizer, distance} <- metric(options, :energy_distance),
         {:ok, reference_sets} <-
           normalize_samples(reference_samples, :energy_distance, normalizer),
         {:ok, candidate_sets} <-
           normalize_samples(candidate_samples, :energy_distance, normalizer) do
      {:ok, energy_components(reference_sets, candidate_sets, distance)}
    end
  end

  @doc """
  Estimates an upper-tail permutation p-value for lexical energy distance.

  Uses the standard plus-one correction: `(extreme + 1) / (permutations + 1)`.
  Required option: `:seed`. The default number of permutations is 999.
  """
  @spec permutation_test(term(), term(), keyword()) :: {:ok, result()} | {:error, error()}
  def permutation_test(reference_samples, candidate_samples, options \\ [])

  def permutation_test(reference_samples, candidate_samples, options) when is_list(options) do
    with :ok <- validate_keyword_options(options, :permutation_test),
         {:ok, seed} <- required_seed(options, :permutation_test),
         {:ok, permutations} <- positive_option(options, :permutations, 999, :permutation_test),
         :ok <-
           require_energy_samples(reference_samples, candidate_samples, :permutation_test),
         {:ok, normalizer, distance} <- metric(options, :permutation_test),
         {:ok, reference_sets} <-
           normalize_samples(reference_samples, :permutation_test, normalizer),
         {:ok, candidate_sets} <-
           normalize_samples(candidate_samples, :permutation_test, normalizer) do
      observed = energy_components(reference_sets, candidate_sets, distance)
      observed_energy = observed["energy_distance"]
      reference_size = length(reference_sets)
      combined = reference_sets ++ candidate_sets
      distance_matrix = distance_matrix(combined, distance)
      random_state = random_state(seed)

      {permuted_energies, _random_state} =
        Enum.map_reduce(1..permutations, random_state, fn _iteration, state ->
          {shuffled, state} = shuffle(Enum.to_list(0..(length(combined) - 1)), state)
          {permuted_reference, permuted_candidate} = Enum.split(shuffled, reference_size)

          {energy_value_from_matrix(permuted_reference, permuted_candidate, distance_matrix),
           state}
        end)

      extreme_count = Enum.count(permuted_energies, &(&1 >= observed_energy))

      {:ok,
       %{
         "observed" => observed,
         "observed_energy" => observed_energy,
         "p_value" => (extreme_count + 1) / (permutations + 1),
         "extreme_permutations" => extreme_count,
         "permutations" => permutations,
         "seed" => seed
       }}
    end
  end

  def permutation_test(_reference_samples, _candidate_samples, _options) do
    {:error,
     %{type: :invalid_options, operation: :permutation_test, reason: :must_be_a_keyword_list}}
  end

  @doc """
  Builds an empirical null distribution by repeatedly shuffling and splitting
  pooled baseline/control samples without replacement.

  Required option: `:seed`. Defaults to 200 iterations and two near-equal
  groups. `:reference_size` and `:candidate_size` may override those sizes.
  """
  @spec null_distribution(term(), keyword()) :: {:ok, result()} | {:error, error()}
  def null_distribution(null_batches, options \\ [])

  def null_distribution(null_batches, options) when is_list(options) do
    with :ok <- validate_keyword_options(options, :null_distribution),
         {:ok, seed} <- required_seed(options, :null_distribution),
         {:ok, iterations} <- positive_option(options, :iterations, 200, :null_distribution),
         {:ok, normalizer, distance} <- metric(options, :null_distribution),
         {:ok, null_data} <- normalize_null_batches(null_batches, normalizer),
         {:ok, reference_size, candidate_size} <-
           resample_sizes(options, length(null_data.pool)) do
      random_state = random_state(seed)
      indexes = Enum.to_list(0..(length(null_data.pool) - 1))
      distance_matrix = distance_matrix(null_data.pool, distance)

      {energies, _random_state} =
        Enum.map_reduce(1..iterations, random_state, fn _iteration, state ->
          {shuffled, state} = shuffle(indexes, state)
          {reference, remaining} = Enum.split(shuffled, reference_size)
          {candidate, _unused} = Enum.split(remaining, candidate_size)

          {energy_value_from_matrix(reference, candidate, distance_matrix), state}
        end)

      {:ok,
       %{
         "energies" => energies,
         "iterations" => iterations,
         "seed" => seed,
         "reference_size" => reference_size,
         "candidate_size" => candidate_size,
         "source_conditions" => null_data.conditions,
         "source_counts" => null_data.counts
       }}
    end
  end

  def null_distribution(_null_batches, _options) do
    {:error,
     %{type: :invalid_options, operation: :null_distribution, reason: :must_be_a_keyword_list}}
  end

  @doc """
  Calibrates an empirical upper-tail threshold from null data only.

  The default quantile is `0.95`; it uses the nearest-rank empirical quantile.
  All options accepted by `null_distribution/2` are supported.
  """
  @spec calibrate_threshold(term(), keyword()) :: {:ok, result()} | {:error, error()}
  def calibrate_threshold(null_batches, options \\ [])

  def calibrate_threshold(null_batches, options) when is_list(options) do
    with :ok <- validate_keyword_options(options, :calibrate_threshold),
         {:ok, quantile} <- probability_option(options, :quantile, 0.95, :calibrate_threshold),
         {:ok, distribution} <- null_distribution(null_batches, options) do
      threshold = empirical_quantile(distribution["energies"], quantile)

      {:ok,
       distribution
       |> Map.put("null_energies", distribution["energies"])
       |> Map.delete("energies")
       |> Map.put("quantile", quantile)
       |> Map.put("threshold", threshold)}
    end
  end

  def calibrate_threshold(_null_batches, _options) do
    {:error,
     %{
       type: :invalid_options,
       operation: :calibrate_threshold,
       reason: :must_be_a_keyword_list
     }}
  end

  @doc """
  Applies Benjamini-Hochberg correction and preserves input ordering.
  """
  @spec benjamini_hochberg(term()) :: {:ok, [float()]} | {:error, error()}
  def benjamini_hochberg(p_values) when is_list(p_values) and p_values != [] do
    if Enum.all?(p_values, &probability?/1) do
      count = length(p_values)

      ranked =
        p_values
        |> Enum.map(&(&1 * 1.0))
        |> Enum.with_index()
        |> Enum.sort_by(fn {p_value, _original_index} -> p_value end)
        |> Enum.with_index(1)

      {adjusted_with_indexes, _running_minimum} =
        ranked
        |> Enum.reverse()
        |> Enum.reduce({[], 1.0}, fn {{p_value, original_index}, rank},
                                     {adjusted, running_minimum} ->
          corrected = min(running_minimum, min(1.0, p_value * count / rank))
          {[{original_index, corrected} | adjusted], corrected}
        end)

      adjusted =
        adjusted_with_indexes
        |> Enum.sort_by(fn {original_index, _p_value} -> original_index end)
        |> Enum.map(fn {_original_index, p_value} -> p_value end)

      {:ok, adjusted}
    else
      {:error,
       %{type: :invalid_p_values, operation: :benjamini_hochberg, reason: :outside_unit_interval}}
    end
  end

  def benjamini_hochberg([]) do
    {:error,
     %{
       type: :insufficient_data,
       operation: :benjamini_hochberg,
       minimum_count: 1,
       actual_count: 0
     }}
  end

  def benjamini_hochberg(_p_values) do
    {:error, %{type: :invalid_p_values, operation: :benjamini_hochberg, reason: :must_be_a_list}}
  end

  @doc """
  Returns the arithmetic mean of one or more finite numeric values.
  """
  @spec mean(term()) :: {:ok, float()} | {:error, error()}
  def mean(values) when is_list(values) and values != [] do
    if valid_numbers?(values) do
      {:ok, mean_value(values)}
    else
      {:error, %{type: :invalid_values, operation: :mean, reason: :must_be_numeric}}
    end
  end

  def mean([]) do
    {:error, %{type: :insufficient_data, operation: :mean, minimum_count: 1, actual_count: 0}}
  end

  def mean(_values),
    do: {:error, %{type: :invalid_values, operation: :mean, reason: :must_be_a_list}}

  @doc """
  Returns sample standard deviation using denominator `n - 1`.
  """
  @spec sample_standard_deviation(term()) :: {:ok, float()} | {:error, error()}
  def sample_standard_deviation(values) when is_list(values) do
    cond do
      length(values) < 2 ->
        {:error,
         %{
           type: :insufficient_data,
           operation: :sample_standard_deviation,
           minimum_count: 2,
           actual_count: length(values)
         }}

      not valid_numbers?(values) ->
        {:error,
         %{
           type: :invalid_values,
           operation: :sample_standard_deviation,
           reason: :must_be_numeric
         }}

      true ->
        average = mean_value(values)
        squared_deviations = Enum.map(values, &:math.pow(&1 - average, 2))
        variance = Enum.sum(squared_deviations) / (length(values) - 1)
        {:ok, :math.sqrt(variance)}
    end
  end

  def sample_standard_deviation(_values) do
    {:error,
     %{
       type: :invalid_values,
       operation: :sample_standard_deviation,
       reason: :must_be_a_list
     }}
  end

  @doc """
  Describes at least two numeric observations using sample standard deviation.
  """
  @spec summarize(term()) :: {:ok, result()} | {:error, error()}
  def summarize(values) do
    with {:ok, average} <- mean(values),
         {:ok, standard_deviation} <- sample_standard_deviation(values) do
      {:ok,
       %{
         "count" => length(values),
         "mean" => average,
         "sample_standard_deviation" => standard_deviation,
         "minimum" => Enum.min(values),
         "maximum" => Enum.max(values)
       }}
    end
  end

  defp require_sample_count(samples, minimum, operation, group \\ nil)

  defp require_sample_count(samples, minimum, operation, group) when is_list(samples) do
    if length(samples) >= minimum do
      :ok
    else
      {:error,
       %{
         type: :insufficient_data,
         operation: operation,
         group: group,
         minimum_count: minimum,
         actual_count: length(samples)
       }}
    end
  end

  defp require_sample_count(_samples, minimum, operation, group) do
    {:error,
     %{
       type: :invalid_samples,
       operation: operation,
       group: group,
       minimum_count: minimum,
       reason: :must_be_a_list
     }}
  end

  defp require_energy_samples(reference_samples, candidate_samples, operation) do
    with :ok <- require_sample_count(reference_samples, 2, operation, :reference),
         :ok <- require_sample_count(candidate_samples, 2, operation, :candidate) do
      :ok
    end
  end

  defp normalize_samples(samples, operation, normalizer) do
    samples
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {sample, index}, {:ok, normalized} ->
      case normalizer.(sample) do
        {:ok, word_set} ->
          {:cont, {:ok, [word_set | normalized]}}

        {:error, error} ->
          {:halt,
           {:error,
            %{
              type: :invalid_sample,
              operation: operation,
              sample_index: index,
              reason: error
            }}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, error} -> {:error, error}
    end)
  end

  defp energy_components(reference_sets, candidate_sets, distance) do
    within_reference_mean = reference_sets |> within_set_distances(distance) |> mean_value()
    within_candidate_mean = candidate_sets |> within_set_distances(distance) |> mean_value()
    cross_mean = reference_sets |> cross_set_distances(candidate_sets, distance) |> mean_value()

    %{
      "within_reference_mean" => within_reference_mean,
      "within_candidate_mean" => within_candidate_mean,
      "cross_mean" => cross_mean,
      "energy_distance" => 2.0 * cross_mean - within_reference_mean - within_candidate_mean,
      "reference_count" => length(reference_sets),
      "candidate_count" => length(candidate_sets),
      "within_reference_pair_count" => pair_count(length(reference_sets)),
      "within_candidate_pair_count" => pair_count(length(candidate_sets)),
      "cross_pair_count" => length(reference_sets) * length(candidate_sets)
    }
  end

  defp energy_value_from_matrix(reference_indexes, candidate_indexes, distance_matrix) do
    within_reference_mean =
      reference_indexes
      |> within_index_distances(distance_matrix)
      |> mean_value()

    within_candidate_mean =
      candidate_indexes
      |> within_index_distances(distance_matrix)
      |> mean_value()

    cross_mean =
      reference_indexes
      |> cross_index_distances(candidate_indexes, distance_matrix)
      |> mean_value()

    2.0 * cross_mean - within_reference_mean - within_candidate_mean
  end

  defp distance_matrix(samples, distance) do
    samples
    |> Enum.with_index()
    |> Enum.map(fn {left, left_index} ->
      samples
      |> Enum.with_index()
      |> Enum.map(fn
        {_right, right_index} when left_index == right_index -> 0.0
        {right, _right_index} -> distance.(left, right)
      end)
      |> List.to_tuple()
    end)
    |> List.to_tuple()
  end

  defp within_index_distances([], _distance_matrix), do: []

  defp within_index_distances([head | tail], distance_matrix) do
    Enum.map(tail, &matrix_distance(distance_matrix, head, &1)) ++
      within_index_distances(tail, distance_matrix)
  end

  defp cross_index_distances(reference_indexes, candidate_indexes, distance_matrix) do
    for reference <- reference_indexes,
        candidate <- candidate_indexes,
        do: matrix_distance(distance_matrix, reference, candidate)
  end

  defp matrix_distance(distance_matrix, left, right),
    do: distance_matrix |> elem(left) |> elem(right)

  defp within_set_distances([], _distance), do: []

  defp within_set_distances([head | tail], distance) do
    Enum.map(tail, &distance.(head, &1)) ++ within_set_distances(tail, distance)
  end

  defp cross_set_distances(reference_sets, candidate_sets, distance) do
    for reference <- reference_sets,
        candidate <- candidate_sets,
        do: distance.(reference, candidate)
  end

  defp pair_count(sample_count), do: div(sample_count * (sample_count - 1), 2)

  defp normalize_null_batches(null_batches, normalizer)
       when is_list(null_batches) and null_batches != [] do
    null_batches
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, %{pool: [], conditions: MapSet.new(), counts: %{}}},
      &normalize_null_batch(&1, &2, normalizer)
    )
    |> then(fn
      {:ok, data} ->
        {:ok,
         %{
           pool: Enum.reverse(data.pool),
           conditions: data.conditions |> MapSet.to_list() |> Enum.sort(),
           counts: data.counts
         }}

      {:error, error} ->
        {:error, error}
    end)
  end

  defp normalize_null_batches([], _normalizer) do
    {:error,
     %{
       type: :insufficient_data,
       operation: :null_distribution,
       minimum_batch_count: 1,
       actual_batch_count: 0
     }}
  end

  defp normalize_null_batches(_null_batches, _normalizer) do
    {:error,
     %{
       type: :invalid_calibration_input,
       operation: :null_distribution,
       reason: :must_be_a_list
     }}
  end

  defp normalize_null_batch({batch, batch_index}, {:ok, data}, normalizer) when is_map(batch) do
    condition = Map.get(batch, "condition", Map.get(batch, :condition))
    samples = Map.get(batch, "samples", Map.get(batch, :samples))

    cond do
      condition not in @null_conditions ->
        {:halt,
         {:error,
          %{
            type: :invalid_calibration_input,
            operation: :null_distribution,
            batch_index: batch_index,
            condition: condition,
            reason: :non_null_condition
          }}}

      not is_list(samples) ->
        {:halt,
         {:error,
          %{
            type: :invalid_calibration_input,
            operation: :null_distribution,
            batch_index: batch_index,
            reason: :samples_must_be_a_list
          }}}

      true ->
        case normalize_samples(samples, :null_distribution, normalizer) do
          {:ok, normalized_samples} ->
            updated = %{
              pool: Enum.reverse(normalized_samples, data.pool),
              conditions: MapSet.put(data.conditions, condition),
              counts: Map.update(data.counts, condition, length(samples), &(&1 + length(samples)))
            }

            {:cont, {:ok, updated}}

          {:error, error} ->
            {:halt, {:error, Map.put(error, :batch_index, batch_index)}}
        end
    end
  end

  defp normalize_null_batch({_batch, batch_index}, {:ok, _data}, _normalizer) do
    {:halt,
     {:error,
      %{
        type: :invalid_calibration_input,
        operation: :null_distribution,
        batch_index: batch_index,
        reason: :batch_must_be_a_map
      }}}
  end

  defp resample_sizes(options, pool_size) do
    default_reference_size = div(pool_size, 2)
    default_candidate_size = pool_size - default_reference_size
    reference_size = Keyword.get(options, :reference_size, default_reference_size)
    candidate_size = Keyword.get(options, :candidate_size, default_candidate_size)

    cond do
      not (is_integer(reference_size) and is_integer(candidate_size)) ->
        {:error,
         %{
           type: :invalid_options,
           operation: :null_distribution,
           reason: :sample_sizes_must_be_integers
         }}

      reference_size < 2 or candidate_size < 2 ->
        {:error,
         %{
           type: :insufficient_data,
           operation: :null_distribution,
           minimum_samples_per_group: 2,
           reference_size: reference_size,
           candidate_size: candidate_size,
           available_samples: pool_size
         }}

      reference_size + candidate_size > pool_size ->
        {:error,
         %{
           type: :insufficient_data,
           operation: :null_distribution,
           requested_samples: reference_size + candidate_size,
           available_samples: pool_size
         }}

      true ->
        {:ok, reference_size, candidate_size}
    end
  end

  defp validate_keyword_options(options, operation) do
    if Keyword.keyword?(options) do
      :ok
    else
      {:error, %{type: :invalid_options, operation: operation, reason: :must_be_a_keyword_list}}
    end
  end

  defp metric(options, operation) do
    normalizer = Keyword.get(options, :normalizer, &Lexical.normalize/1)
    distance = Keyword.get(options, :distance, &Lexical.set_distance/2)

    if is_function(normalizer, 1) and is_function(distance, 2) do
      {:ok, normalizer, distance}
    else
      {:error,
       %{
         type: :invalid_options,
         operation: operation,
         reason: :metric_functions_have_invalid_arity
       }}
    end
  end

  defp required_seed(options, operation) do
    case Keyword.fetch(options, :seed) do
      {:ok, seed} when is_integer(seed) ->
        {:ok, seed}

      {:ok, _seed} ->
        {:error,
         %{
           type: :invalid_option,
           operation: operation,
           option: :seed,
           reason: :must_be_an_integer
         }}

      :error ->
        {:error, %{type: :invalid_option, operation: operation, option: :seed, reason: :required}}
    end
  end

  defp positive_option(options, name, default, operation) do
    value = Keyword.get(options, name, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error,
       %{
         type: :invalid_option,
         operation: operation,
         option: name,
         reason: :must_be_a_positive_integer
       }}
    end
  end

  defp probability_option(options, name, default, operation) do
    value = Keyword.get(options, name, default)

    if probability?(value) do
      {:ok, value * 1.0}
    else
      {:error,
       %{
         type: :invalid_option,
         operation: operation,
         option: name,
         reason: :must_be_between_zero_and_one
       }}
    end
  end

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp valid_numbers?(values), do: Enum.all?(values, &is_number/1)

  defp mean_value(values), do: Enum.sum(values) / length(values)

  defp empirical_quantile(values, quantile) do
    sorted = Enum.sort(values)
    rank = max(1, ceil(quantile * length(sorted)))
    Enum.at(sorted, rank - 1)
  end

  defp random_state(seed) do
    <<first::unsigned-32, second::unsigned-32, third::unsigned-32, _rest::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(seed, [:deterministic]))

    :rand.seed_s(:exsss, {first + 1, second + 1, third + 1})
  end

  defp shuffle(items, random_state) when length(items) <= 1, do: {items, random_state}

  defp shuffle(items, random_state) do
    {shuffled, random_state} =
      Enum.reduce(length(items)..2//-1, {List.to_tuple(items), random_state}, fn position,
                                                                                 {tuple, state} ->
        {swap_position, state} = :rand.uniform_s(position, state)
        left = elem(tuple, position - 1)
        right = elem(tuple, swap_position - 1)

        tuple =
          tuple
          |> put_elem(position - 1, right)
          |> put_elem(swap_position - 1, left)

        {tuple, state}
      end)

    {Tuple.to_list(shuffled), random_state}
  end
end
