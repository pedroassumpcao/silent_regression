defmodule SilentRegression.Spike.SemanticLayer.Calibration do
  @moduledoc """
  Immutable calibration contract for one versioned semantic representation.

  Null thresholds can reference only baseline and control run artifacts. The
  strict schema rejects fixture IDs, labels, or arbitrary source objects so
  approved held-out judgments cannot leak into calibration.
  """

  alias SilentRegression.Spike.SemanticLayer.ArtifactValidation
  alias SilentRegression.Spike.SemanticLayer.RepresentationSpec
  alias SilentRegression.Spike.Validation

  @schema_version 1
  @artifact_type "semantic_calibration"
  @fields [
    :schema_version,
    :artifact_type,
    :calibration_id,
    :created_at,
    :git_revision,
    :status,
    :representation,
    :case_ids,
    :source_runs,
    :settings,
    :thresholds
  ]

  @enforce_keys @fields -- [:git_revision]
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          artifact_type: String.t(),
          calibration_id: String.t(),
          created_at: DateTime.t(),
          git_revision: String.t() | nil,
          status: String.t(),
          representation: map(),
          case_ids: [String.t()],
          source_runs: [map()],
          settings: map(),
          thresholds: [map()]
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
         {:ok, calibration_id} <- required(attributes, :calibration_id),
         :ok <- Validation.non_empty_string(calibration_id, :calibration_id, __MODULE__),
         {:ok, created_at_value} <- required(attributes, :created_at),
         {:ok, created_at} <- Validation.parse_datetime(created_at_value, :created_at, __MODULE__),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, status} <- required(attributes, :status),
         :ok <- validate_status(status),
         {:ok, representation} <- required(attributes, :representation),
         :ok <- validate_representation(representation),
         {:ok, case_ids} <- required(attributes, :case_ids),
         :ok <- ArtifactValidation.unique_strings(case_ids, :case_ids, __MODULE__),
         {:ok, source_runs} <- required(attributes, :source_runs),
         :ok <- ArtifactValidation.source_runs(source_runs, :source_runs, __MODULE__),
         {:ok, settings} <- required(attributes, :settings),
         :ok <- validate_settings(settings),
         {:ok, thresholds} <- required(attributes, :thresholds),
         :ok <- validate_thresholds(thresholds, case_ids, settings) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         artifact_type: artifact_type,
         calibration_id: calibration_id,
         created_at: created_at,
         git_revision: git_revision,
         status: status,
         representation: representation,
         case_ids: case_ids,
         source_runs: source_runs,
         settings: settings,
         thresholds: thresholds
       }}
    end
  end

  def new(_attributes), do: validation_error(:attributes, :must_be_a_map)

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = calibration) do
    case calibration |> Map.from_struct() |> new() do
      {:ok, _calibration} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = calibration) do
    %{
      "schema_version" => calibration.schema_version,
      "artifact_type" => calibration.artifact_type,
      "calibration_id" => calibration.calibration_id,
      "created_at" => DateTime.to_iso8601(calibration.created_at),
      "git_revision" => calibration.git_revision,
      "status" => calibration.status,
      "representation" => calibration.representation,
      "case_ids" => calibration.case_ids,
      "source_runs" => calibration.source_runs,
      "settings" => calibration.settings,
      "thresholds" => calibration.thresholds
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_status("frozen"), do: :ok
  defp validate_status(_status), do: validation_error(:status, :must_be_frozen)

  defp validate_representation(representation) do
    keys = ~w(representation_id artifact_sha256 method_name method_version parameters_sha256)

    with :ok <-
           ArtifactValidation.exact_json_keys(
             representation,
             keys,
             :representation,
             __MODULE__
           ),
         :ok <-
           Validation.non_empty_string(
             representation["representation_id"],
             :representation,
             __MODULE__
           ),
         :ok <-
           ArtifactValidation.sha256(
             representation["artifact_sha256"],
             :representation,
             __MODULE__
           ),
         :ok <-
           Validation.non_empty_string(
             representation["method_name"],
             :representation,
             __MODULE__
           ),
         :ok <-
           ArtifactValidation.enum(
             representation["method_name"],
             RepresentationSpec.methods(),
             :representation,
             __MODULE__
           ),
         :ok <-
           Validation.positive_integer(
             representation["method_version"],
             :representation,
             __MODULE__
           ),
         :ok <-
           ArtifactValidation.sha256(
             representation["parameters_sha256"],
             :representation,
             __MODULE__
           ) do
      :ok
    end
  end

  defp validate_settings(settings) do
    keys =
      ~w(seed iterations quantile adjusted_p_alpha baseline_group_size control_group_size)

    with :ok <- ArtifactValidation.exact_json_keys(settings, keys, :settings, __MODULE__),
         :ok <- Validation.non_negative_integer(settings["seed"], :settings, __MODULE__),
         :ok <- Validation.positive_integer(settings["iterations"], :settings, __MODULE__),
         :ok <-
           ArtifactValidation.probability(
             settings["quantile"],
             :settings,
             __MODULE__,
             allow_zero: false,
             allow_one: false
           ),
         :ok <-
           ArtifactValidation.probability(
             settings["adjusted_p_alpha"],
             :settings,
             __MODULE__,
             allow_zero: false,
             allow_one: false
           ),
         :ok <-
           Validation.positive_integer(settings["baseline_group_size"], :settings, __MODULE__),
         :ok <-
           Validation.positive_integer(settings["control_group_size"], :settings, __MODULE__) do
      :ok
    end
  end

  defp validate_thresholds(thresholds, case_ids, settings) do
    with :ok <- Validation.json_object_list(thresholds, :thresholds, __MODULE__) do
      cond do
        Enum.map(thresholds, & &1["case_id"]) != case_ids ->
          validation_error(:thresholds, :must_match_case_ids_in_order)

        not Enum.all?(thresholds, &valid_threshold?(&1, settings)) ->
          validation_error(:thresholds, :contains_invalid_threshold)

        true ->
          :ok
      end
    end
  end

  defp valid_threshold?(threshold, settings) do
    keys =
      ~w(case_id threshold null_energies iterations baseline_size control_size empirical_exceedance_rate)

    ArtifactValidation.exact_json_keys(threshold, keys, :thresholds, __MODULE__) == :ok and
      non_empty_string?(threshold["case_id"]) and is_number(threshold["threshold"]) and
      is_list(threshold["null_energies"]) and threshold["null_energies"] != [] and
      Enum.all?(threshold["null_energies"], &is_number/1) and
      threshold["iterations"] == settings["iterations"] and
      threshold["baseline_size"] == settings["baseline_group_size"] and
      threshold["control_size"] == settings["control_group_size"] and
      valid_probability?(threshold["empirical_exceedance_rate"])
  end

  defp required(attributes, field), do: Validation.fetch_required(attributes, field, __MODULE__)

  defp validation_error(field, reason),
    do: {:error, ArtifactValidation.error(__MODULE__, field, reason)}

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_probability?(value), do: is_number(value) and value >= 0 and value <= 1
end
