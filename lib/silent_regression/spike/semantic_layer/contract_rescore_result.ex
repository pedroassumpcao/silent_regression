defmodule SilentRegression.Spike.SemanticLayer.ContractRescoreResult do
  @moduledoc """
  Versioned result contract for local semantic-contract rescoring.

  Summary counts are recomputed from fixture-level results during validation so
  a persisted report cannot claim outcomes that its evidence does not contain.
  """

  alias SilentRegression.Spike.SemanticLayer.ArtifactValidation
  alias SilentRegression.Spike.Validation

  @schema_version 1
  @artifact_type "semantic_contract_rescore"
  @fields [
    :schema_version,
    :artifact_type,
    :evaluation_id,
    :created_at,
    :git_revision,
    :contract_set,
    :sources,
    :summary,
    :results,
    :provider_calls
  ]

  @enforce_keys @fields -- [:git_revision]
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          artifact_type: String.t(),
          evaluation_id: String.t(),
          created_at: DateTime.t(),
          git_revision: String.t() | nil,
          contract_set: map(),
          sources: [map()],
          summary: map(),
          results: [map()],
          provider_calls: non_neg_integer()
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
         {:ok, evaluation_id} <- required(attributes, :evaluation_id),
         :ok <- Validation.non_empty_string(evaluation_id, :evaluation_id, __MODULE__),
         {:ok, created_at_value} <- required(attributes, :created_at),
         {:ok, created_at} <- Validation.parse_datetime(created_at_value, :created_at, __MODULE__),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, contract_set} <- required(attributes, :contract_set),
         :ok <- validate_contract_set(contract_set),
         {:ok, sources} <- required(attributes, :sources),
         :ok <- validate_sources(sources),
         {:ok, results} <- required(attributes, :results),
         :ok <- validate_results(results),
         {:ok, summary} <- required(attributes, :summary),
         :ok <- validate_summary(summary, results),
         {:ok, provider_calls} <- required(attributes, :provider_calls),
         :ok <- validate_provider_calls(provider_calls) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         artifact_type: artifact_type,
         evaluation_id: evaluation_id,
         created_at: created_at,
         git_revision: git_revision,
         contract_set: contract_set,
         sources: sources,
         summary: summary,
         results: results,
         provider_calls: provider_calls
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
      "evaluation_id" => result.evaluation_id,
      "created_at" => DateTime.to_iso8601(result.created_at),
      "git_revision" => result.git_revision,
      "contract_set" => result.contract_set,
      "sources" => result.sources,
      "summary" => result.summary,
      "results" => result.results,
      "provider_calls" => result.provider_calls
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  @spec summary([map()]) :: map()
  def summary(results) do
    %{
      "fixture_count" => length(results),
      "matched_expectation_count" => Enum.count(results, & &1["matched_expectation"]),
      "expected_pass_count" => Enum.count(results, & &1["expected_contract_pass"]),
      "expected_fail_count" => Enum.count(results, &(not &1["expected_contract_pass"])),
      "expected_pass_matched_count" =>
        Enum.count(
          results,
          &(&1["expected_contract_pass"] and &1["actual_contract_pass"])
        ),
      "expected_fail_matched_count" =>
        Enum.count(
          results,
          &(not &1["expected_contract_pass"] and not &1["actual_contract_pass"])
        ),
      "actual_pass_count" => Enum.count(results, & &1["actual_contract_pass"]),
      "actual_fail_count" => Enum.count(results, &(not &1["actual_contract_pass"])),
      "by_split" => grouped_summary(results, "split"),
      "by_case" => grouped_summary(results, "case_id"),
      "by_failure_mode" => failure_mode_summary(results)
    }
  end

  defp grouped_summary(results, field) do
    results
    |> Enum.group_by(& &1[field])
    |> Enum.map(fn {value, group} ->
      %{
        field => value,
        "fixture_count" => length(group),
        "matched_expectation_count" => Enum.count(group, & &1["matched_expectation"]),
        "expected_pass_count" => Enum.count(group, & &1["expected_contract_pass"]),
        "expected_fail_count" => Enum.count(group, &(not &1["expected_contract_pass"])),
        "expected_pass_matched_count" =>
          Enum.count(
            group,
            &(&1["expected_contract_pass"] and &1["actual_contract_pass"])
          ),
        "expected_fail_matched_count" =>
          Enum.count(
            group,
            &(not &1["expected_contract_pass"] and not &1["actual_contract_pass"])
          ),
        "actual_pass_count" => Enum.count(group, & &1["actual_contract_pass"]),
        "actual_fail_count" => Enum.count(group, &(not &1["actual_contract_pass"]))
      }
    end)
    |> Enum.sort_by(& &1[field])
  end

  defp failure_mode_summary(results) do
    results
    |> Enum.flat_map(fn result ->
      Enum.map(result["failure_modes"], &{&1, result})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {failure_mode, group} ->
      %{
        "failure_mode" => failure_mode,
        "fixture_count" => length(group),
        "detected_count" => Enum.count(group, &(not &1["actual_contract_pass"])),
        "matched_expectation_count" => Enum.count(group, & &1["matched_expectation"])
      }
    end)
    |> Enum.sort_by(& &1["failure_mode"])
  end

  defp validate_contract_set(contract_set) do
    keys = ~w(contract_set_id contract_set_version fingerprint)

    with :ok <-
           ArtifactValidation.exact_json_keys(contract_set, keys, :contract_set, __MODULE__),
         :ok <-
           Validation.non_empty_string(
             contract_set["contract_set_id"],
             :contract_set,
             __MODULE__
           ),
         :ok <-
           Validation.positive_integer(
             contract_set["contract_set_version"],
             :contract_set,
             __MODULE__
           ),
         :ok <- ArtifactValidation.sha256(contract_set["fingerprint"], :contract_set, __MODULE__) do
      :ok
    end
  end

  defp validate_sources(sources) do
    with :ok <- Validation.json_object_list(sources, :sources, __MODULE__) do
      source_types = Enum.map(sources, & &1["source_type"])

      cond do
        length(sources) != 2 ->
          validation_error(:sources, :must_contain_authoring_and_paired_sources)

        Enum.sort(source_types) != ["paired_fixture_set", "task_10_authoring"] ->
          validation_error(:sources, :must_contain_authoring_and_paired_sources)

        not Enum.all?(sources, &valid_source?/1) ->
          validation_error(:sources, :contains_invalid_source)

        true ->
          :ok
      end
    end
  end

  defp valid_source?(source) do
    keys = ~w(source_type artifact_id artifact_sha256 split status)

    ArtifactValidation.exact_json_keys(source, keys, :sources, __MODULE__) == :ok and
      non_empty_string?(source["artifact_id"]) and valid_sha256?(source["artifact_sha256"]) and
      source["status"] == "approved" and
      case source["source_type"] do
        "task_10_authoring" -> source["split"] == "authoring"
        "paired_fixture_set" -> source["split"] in ~w(tuning heldout)
        _source_type -> false
      end
  end

  defp validate_results(results) do
    with :ok <- Validation.json_object_list(results, :results, __MODULE__) do
      fixture_ids = Enum.map(results, & &1["fixture_id"])

      cond do
        results == [] ->
          validation_error(:results, :must_be_a_non_empty_list)

        Enum.uniq(fixture_ids) != fixture_ids ->
          validation_error(:results, :fixture_ids_must_be_unique)

        not Enum.all?(results, &valid_result?/1) ->
          validation_error(:results, :contains_invalid_result)

        true ->
          :ok
      end
    end
  end

  defp valid_result?(result) do
    keys =
      ~w(fixture_id case_id split label failure_modes expected_contract_pass actual_contract_pass matched_expectation contract_id contract_fingerprint checks)

    ArtifactValidation.exact_json_keys(result, keys, :results, __MODULE__) == :ok and
      Enum.all?(~w(fixture_id case_id label contract_id), &non_empty_string?(result[&1])) and
      result["split"] in ~w(authoring tuning heldout) and
      valid_string_list?(result["failure_modes"]) and
      is_boolean(result["expected_contract_pass"]) and
      is_boolean(result["actual_contract_pass"]) and
      result["matched_expectation"] ==
        (result["expected_contract_pass"] == result["actual_contract_pass"]) and
      valid_sha256?(result["contract_fingerprint"]) and is_list(result["checks"]) and
      result["checks"] != [] and Validation.json_value?(result["checks"])
  end

  defp validate_summary(summary, results) do
    if summary == summary(results),
      do: :ok,
      else: validation_error(:summary, :must_match_fixture_results)
  end

  defp validate_provider_calls(0), do: :ok

  defp validate_provider_calls(_provider_calls),
    do: validation_error(:provider_calls, :must_be_zero)

  defp required(attributes, field), do: Validation.fetch_required(attributes, field, __MODULE__)

  defp validation_error(field, reason),
    do: {:error, ArtifactValidation.error(__MODULE__, field, reason)}

  defp valid_string_list?(values) do
    is_list(values) and Enum.all?(values, &non_empty_string?/1) and Enum.uniq(values) == values
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
end
