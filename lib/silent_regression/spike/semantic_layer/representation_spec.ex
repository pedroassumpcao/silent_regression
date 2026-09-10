defmodule SilentRegression.Spike.SemanticLayer.RepresentationSpec do
  @moduledoc """
  Versioned configuration and fit-provenance contract for a cheap semantic
  representation. Fixture labels are deliberately absent from the fit schema;
  only immutable baseline and control run references are accepted.
  """

  alias SilentRegression.Spike.SemanticLayer.ArtifactValidation
  alias SilentRegression.Spike.Validation

  @schema_version 1
  @artifact_type "semantic_representation_spec"
  @methods ~w(word_ngram character_ngram field_aware)
  @fields [
    :schema_version,
    :artifact_type,
    :representation_id,
    :created_at,
    :git_revision,
    :method,
    :case_ids,
    :fit_sources,
    :fit_observation_ids,
    :fit_policy
  ]

  @enforce_keys @fields -- [:git_revision]
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          artifact_type: String.t(),
          representation_id: String.t(),
          created_at: DateTime.t(),
          git_revision: String.t() | nil,
          method: map(),
          case_ids: [String.t()],
          fit_sources: [map()],
          fit_observation_ids: [String.t()],
          fit_policy: map()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec artifact_type() :: String.t()
  def artifact_type, do: @artifact_type

  @spec methods() :: [String.t()]
  def methods, do: @methods

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
         {:ok, representation_id} <- required(attributes, :representation_id),
         :ok <- Validation.non_empty_string(representation_id, :representation_id, __MODULE__),
         {:ok, created_at_value} <- required(attributes, :created_at),
         {:ok, created_at} <- Validation.parse_datetime(created_at_value, :created_at, __MODULE__),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, method} <- required(attributes, :method),
         :ok <- validate_method(method),
         {:ok, case_ids} <- required(attributes, :case_ids),
         :ok <- ArtifactValidation.unique_strings(case_ids, :case_ids, __MODULE__),
         {:ok, fit_sources} <- required(attributes, :fit_sources),
         :ok <- ArtifactValidation.source_runs(fit_sources, :fit_sources, __MODULE__),
         {:ok, fit_observation_ids} <- required(attributes, :fit_observation_ids),
         :ok <-
           ArtifactValidation.unique_strings(
             fit_observation_ids,
             :fit_observation_ids,
             __MODULE__
           ),
         {:ok, fit_policy} <- required(attributes, :fit_policy),
         :ok <- validate_fit_policy(fit_policy) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         artifact_type: artifact_type,
         representation_id: representation_id,
         created_at: created_at,
         git_revision: git_revision,
         method: method,
         case_ids: case_ids,
         fit_sources: fit_sources,
         fit_observation_ids: fit_observation_ids,
         fit_policy: fit_policy
       }}
    end
  end

  def new(_attributes), do: validation_error(:attributes, :must_be_a_map)

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = representation) do
    case representation |> Map.from_struct() |> new() do
      {:ok, _representation} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = representation) do
    %{
      "schema_version" => representation.schema_version,
      "artifact_type" => representation.artifact_type,
      "representation_id" => representation.representation_id,
      "created_at" => DateTime.to_iso8601(representation.created_at),
      "git_revision" => representation.git_revision,
      "method" => representation.method,
      "case_ids" => representation.case_ids,
      "fit_sources" => representation.fit_sources,
      "fit_observation_ids" => representation.fit_observation_ids,
      "fit_policy" => representation.fit_policy
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_method(method) do
    keys = ~w(name version parameters)

    with :ok <- ArtifactValidation.exact_json_keys(method, keys, :method, __MODULE__),
         :ok <- ArtifactValidation.enum(method["name"], @methods, :method, __MODULE__),
         :ok <- Validation.positive_integer(method["version"], :method, __MODULE__),
         :ok <- Validation.json_object(method["parameters"], :method, __MODULE__) do
      :ok
    end
  end

  defp validate_fit_policy(fit_policy) do
    keys = ~w(version fixture_labels_used allowed_conditions)

    with :ok <-
           ArtifactValidation.exact_json_keys(fit_policy, keys, :fit_policy, __MODULE__) do
      if fit_policy == %{
           "version" => 1,
           "fixture_labels_used" => false,
           "allowed_conditions" => ~w(baseline control)
         },
         do: :ok,
         else: validation_error(:fit_policy, :must_exclude_fixture_labels)
    end
  end

  defp required(attributes, field), do: Validation.fetch_required(attributes, field, __MODULE__)

  defp validation_error(field, reason),
    do: {:error, ArtifactValidation.error(__MODULE__, field, reason)}
end
