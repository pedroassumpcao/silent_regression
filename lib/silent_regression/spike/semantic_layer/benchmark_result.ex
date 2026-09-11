defmodule SilentRegression.Spike.SemanticLayer.BenchmarkResult do
  @moduledoc """
  Versioned result contract for cheap semantic representation benchmarks.

  Method-selection results may contain tuning batches only. Final-evaluation
  results may contain held-out batches only, must use an approved fixture set,
  and record diversity and outcomes for every predeclared seed.
  """

  alias SilentRegression.Spike.SemanticLayer.ArtifactValidation
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.Validation

  @schema_version 1
  @artifact_type "semantic_benchmark_result"
  @evaluation_roles ~w(method_selection final_evaluation)
  @fields [
    :schema_version,
    :artifact_type,
    :result_id,
    :created_at,
    :git_revision,
    :evaluation_role,
    :fixture_set,
    :representations,
    :calibrations,
    :settings,
    :batches,
    :summary
  ]

  @enforce_keys @fields -- [:git_revision]
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          artifact_type: String.t(),
          result_id: String.t(),
          created_at: DateTime.t(),
          git_revision: String.t() | nil,
          evaluation_role: String.t(),
          fixture_set: map(),
          representations: [map()],
          calibrations: [map()],
          settings: map(),
          batches: [map()],
          summary: map()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec artifact_type() :: String.t()
  def artifact_type, do: @artifact_type

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(attributes) when is_map(attributes) do
    schema_version = Validation.fetch_optional(attributes, :schema_version, @schema_version)
    artifact_type = Validation.fetch_optional(attributes, :artifact_type, @artifact_type)
    git_revision = Validation.fetch_optional(attributes, :git_revision, nil)

    with :ok <- ArtifactValidation.known_keys(attributes, @fields, __MODULE__),
         :ok <-
           ArtifactValidation.header(
             schema_version,
             artifact_type,
             @schema_version,
             @artifact_type,
             __MODULE__
           ),
         {:ok, result_id} <- required(attributes, :result_id),
         :ok <- Validation.non_empty_string(result_id, :result_id, __MODULE__),
         {:ok, created_at_value} <- required(attributes, :created_at),
         {:ok, created_at} <- Validation.parse_datetime(created_at_value, :created_at, __MODULE__),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, evaluation_role} <- required(attributes, :evaluation_role),
         :ok <-
           ArtifactValidation.enum(
             evaluation_role,
             @evaluation_roles,
             :evaluation_role,
             __MODULE__
           ),
         {:ok, fixture_set} <- required(attributes, :fixture_set),
         :ok <- validate_fixture_set(fixture_set),
         {:ok, representations} <- required(attributes, :representations),
         :ok <- validate_representations(representations),
         {:ok, calibrations} <- required(attributes, :calibrations),
         :ok <- validate_calibrations(calibrations, representations),
         {:ok, settings} <- required(attributes, :settings),
         :ok <- validate_settings(settings),
         {:ok, batches} <- required(attributes, :batches),
         :ok <- validate_batches(batches, evaluation_role, representations, settings),
         {:ok, summary} <- required(attributes, :summary),
         :ok <- Validation.json_object(summary, :summary, __MODULE__) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         artifact_type: artifact_type,
         result_id: result_id,
         created_at: created_at,
         git_revision: git_revision,
         evaluation_role: evaluation_role,
         fixture_set: fixture_set,
         representations: representations,
         calibrations: calibrations,
         settings: settings,
         batches: batches,
         summary: summary
       }}
    end
  end

  def new(_attributes), do: validation_error(:attributes, :must_be_a_map)

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = result) do
    case result |> Map.from_struct() |> new() do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "schema_version" => result.schema_version,
      "artifact_type" => result.artifact_type,
      "result_id" => result.result_id,
      "created_at" => DateTime.to_iso8601(result.created_at),
      "git_revision" => result.git_revision,
      "evaluation_role" => result.evaluation_role,
      "fixture_set" => result.fixture_set,
      "representations" => result.representations,
      "calibrations" => result.calibrations,
      "settings" => result.settings,
      "batches" => result.batches,
      "summary" => result.summary
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_fixture_set(fixture_set) do
    keys = ~w(fixture_set_id artifact_sha256 status)

    with :ok <-
           ArtifactValidation.exact_json_keys(fixture_set, keys, :fixture_set, __MODULE__),
         :ok <-
           Validation.non_empty_string(
             fixture_set["fixture_set_id"],
             :fixture_set,
             __MODULE__
           ),
         :ok <-
           ArtifactValidation.sha256(
             fixture_set["artifact_sha256"],
             :fixture_set,
             __MODULE__
           ) do
      if fixture_set["status"] == "approved",
        do: :ok,
        else: validation_error(:fixture_set, :must_be_approved)
    end
  end

  defp validate_representations(representations) do
    with :ok <- Validation.json_object_list(representations, :representations, __MODULE__) do
      ids = Enum.map(representations, & &1["representation_id"])

      cond do
        representations == [] ->
          validation_error(:representations, :must_be_a_non_empty_list)

        not Enum.all?(representations, &valid_representation?/1) ->
          validation_error(:representations, :contains_invalid_reference)

        Enum.uniq(ids) != ids ->
          validation_error(:representations, :representation_ids_must_be_unique)

        true ->
          :ok
      end
    end
  end

  defp valid_representation?(representation) do
    keys = ~w(representation_id artifact_sha256 method_name method_version)

    ArtifactValidation.exact_json_keys(
      representation,
      keys,
      :representations,
      __MODULE__
    ) == :ok and
      non_empty_string?(representation["representation_id"]) and
      valid_sha256?(representation["artifact_sha256"]) and
      non_empty_string?(representation["method_name"]) and
      is_integer(representation["method_version"]) and representation["method_version"] > 0
  end

  defp validate_calibrations(calibrations, representations) do
    with :ok <- Validation.json_object_list(calibrations, :calibrations, __MODULE__) do
      representation_ids = Enum.map(representations, & &1["representation_id"])
      calibrated_ids = Enum.map(calibrations, & &1["representation_id"])

      cond do
        not Enum.all?(calibrations, &valid_calibration?/1) ->
          validation_error(:calibrations, :contains_invalid_reference)

        calibrations |> Enum.map(& &1["calibration_id"]) |> Enum.uniq() !=
            Enum.map(calibrations, & &1["calibration_id"]) ->
          validation_error(:calibrations, :calibration_ids_must_be_unique)

        calibrated_ids != representation_ids ->
          validation_error(:calibrations, :must_match_representations_in_order)

        true ->
          :ok
      end
    end
  end

  defp valid_calibration?(calibration) do
    keys = ~w(calibration_id artifact_sha256 representation_id)

    ArtifactValidation.exact_json_keys(calibration, keys, :calibrations, __MODULE__) == :ok and
      non_empty_string?(calibration["calibration_id"]) and
      valid_sha256?(calibration["artifact_sha256"]) and
      non_empty_string?(calibration["representation_id"])
  end

  defp validate_settings(settings) do
    keys =
      ~w(seeds permutations adjusted_p_alpha multiple_comparison_family provider_calls)

    with :ok <- ArtifactValidation.exact_json_keys(settings, keys, :settings, __MODULE__) do
      seeds = settings["seeds"]

      cond do
        not (is_list(seeds) and seeds != [] and
                 Enum.all?(seeds, &(is_integer(&1) and &1 >= 0))) ->
          validation_error(:settings, :seeds_must_be_non_negative_integers)

        Enum.uniq(seeds) != seeds ->
          validation_error(:settings, :seeds_must_be_unique)

        not (is_integer(settings["permutations"]) and settings["permutations"] > 0) ->
          validation_error(:settings, :permutations_must_be_positive)

        not valid_probability?(settings["adjusted_p_alpha"]) ->
          validation_error(:settings, :adjusted_p_alpha_must_be_a_probability)

        settings["multiple_comparison_family"] !=
            "all_representation_batch_comparisons_per_seed" ->
          validation_error(:settings, :multiple_comparison_family_is_unsupported)

        settings["provider_calls"] != 0 ->
          validation_error(:settings, :provider_calls_must_be_zero)

        true ->
          :ok
      end
    end
  end

  defp validate_batches(batches, role, representations, settings) do
    with :ok <- Validation.json_object_list(batches, :batches, __MODULE__) do
      expected_split = if role == "method_selection", do: "tuning", else: "heldout"

      cond do
        batches == [] ->
          validation_error(:batches, :must_be_a_non_empty_list)

        not Enum.all?(
          batches,
          &valid_batch?(&1, expected_split, representations, settings["seeds"])
        ) ->
          validation_error(:batches, :contains_invalid_or_leaky_batch)

        batches |> Enum.map(& &1["batch_id"]) |> Enum.uniq() !=
            Enum.map(batches, & &1["batch_id"]) ->
          validation_error(:batches, :batch_ids_must_be_unique)

        true ->
          :ok
      end
    end
  end

  defp valid_batch?(batch, expected_split, representations, seeds) do
    keys =
      ~w(batch_id case_id split label sample_count unique_parent_count unique_output_count duplicate_output_count representation_results)

    ArtifactValidation.exact_json_keys(batch, keys, :batches, __MODULE__) == :ok and
      non_empty_string?(batch["batch_id"]) and non_empty_string?(batch["case_id"]) and
      batch["split"] == expected_split and batch["label"] in PairedFixtureSet.labels() and
      positive_integer?(batch["sample_count"]) and
      batch["unique_parent_count"] == batch["sample_count"] and
      positive_integer?(batch["unique_output_count"]) and
      batch["unique_output_count"] <= batch["sample_count"] and
      batch["duplicate_output_count"] == batch["sample_count"] - batch["unique_output_count"] and
      valid_representation_results?(batch["representation_results"], representations, seeds)
  end

  defp valid_representation_results?(results, representations, seeds) do
    is_list(results) and length(results) == length(representations) and
      Enum.zip(results, representations)
      |> Enum.all?(fn {result, representation} ->
        result["representation_id"] == representation["representation_id"] and
          result["method_version"] == representation["method_version"] and
          valid_representation_result?(result, seeds)
      end)
  end

  defp valid_representation_result?(result, seeds) do
    keys = ~w(representation_id method_version seed_results)

    ArtifactValidation.exact_json_keys(result, keys, :batches, __MODULE__) == :ok and
      non_empty_string?(result["representation_id"]) and
      positive_integer?(result["method_version"]) and is_list(result["seed_results"]) and
      Enum.map(result["seed_results"], & &1["seed"]) == seeds and
      Enum.all?(result["seed_results"], &valid_seed_result?/1)
  end

  defp valid_seed_result?(result) do
    keys =
      ~w(seed energy_distance raw_p_value adjusted_p_value threshold outcome)

    ArtifactValidation.exact_json_keys(result, keys, :batches, __MODULE__) == :ok and
      is_integer(result["seed"]) and result["seed"] >= 0 and
      is_number(result["energy_distance"]) and is_number(result["threshold"]) and
      valid_probability?(result["raw_p_value"]) and
      valid_probability?(result["adjusted_p_value"]) and
      result["outcome"] in ~w(drift_review no_drift_review)
  end

  defp required(attributes, field), do: Validation.fetch_required(attributes, field, __MODULE__)

  defp validation_error(field, reason),
    do: {:error, ArtifactValidation.error(__MODULE__, field, reason)}

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp valid_probability?(value), do: is_number(value) and value >= 0 and value <= 1
end
