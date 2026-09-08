defmodule SilentRegression.Spike.Calibration do
  @moduledoc """
  Immutable, versioned lexical-threshold calibration artifact.

  A calibration records the exact baseline and control run IDs that supplied
  its null observations, the reproducible random seed and resampling settings,
  and one empirical threshold per frozen case. It is intentionally separate
  from run artifacts so later candidate comparisons cannot rewrite history.
  """

  alias SilentRegression.Spike.Validation

  @schema_version 1

  @enforce_keys [
    :schema_version,
    :calibration_id,
    :created_at,
    :baseline_run_id,
    :control_run_ids,
    :source_run_ids,
    :provenance,
    :settings,
    :thresholds
  ]
  defstruct [
    :schema_version,
    :calibration_id,
    :created_at,
    :git_revision,
    :baseline_run_id,
    :control_run_ids,
    :source_run_ids,
    :provenance,
    :settings,
    :thresholds
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          calibration_id: String.t(),
          created_at: DateTime.t(),
          git_revision: String.t() | nil,
          baseline_run_id: String.t(),
          control_run_ids: [String.t()],
          source_run_ids: [String.t()],
          provenance: map(),
          settings: map(),
          thresholds: [map()]
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(attributes) when is_map(attributes) do
    schema_version = Validation.fetch_optional(attributes, :schema_version, @schema_version)
    git_revision = Validation.fetch_optional(attributes, :git_revision, nil)

    with :ok <- validate_schema_version(schema_version),
         {:ok, calibration_id} <-
           Validation.fetch_required(attributes, :calibration_id, __MODULE__),
         :ok <- Validation.non_empty_string(calibration_id, :calibration_id, __MODULE__),
         {:ok, created_at_value} <-
           Validation.fetch_required(attributes, :created_at, __MODULE__),
         {:ok, created_at} <-
           Validation.parse_datetime(created_at_value, :created_at, __MODULE__),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, baseline_run_id} <-
           Validation.fetch_required(attributes, :baseline_run_id, __MODULE__),
         :ok <- Validation.non_empty_string(baseline_run_id, :baseline_run_id, __MODULE__),
         {:ok, control_run_ids} <-
           Validation.fetch_required(attributes, :control_run_ids, __MODULE__),
         :ok <- validate_control_run_ids(control_run_ids),
         {:ok, source_run_ids} <-
           Validation.fetch_required(attributes, :source_run_ids, __MODULE__),
         :ok <- validate_source_run_ids(source_run_ids, baseline_run_id, control_run_ids),
         {:ok, provenance} <-
           Validation.fetch_required(attributes, :provenance, __MODULE__),
         :ok <- validate_provenance(provenance),
         {:ok, settings} <- Validation.fetch_required(attributes, :settings, __MODULE__),
         :ok <- validate_settings(settings),
         {:ok, thresholds} <- Validation.fetch_required(attributes, :thresholds, __MODULE__),
         :ok <- validate_thresholds(thresholds, provenance) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         calibration_id: calibration_id,
         created_at: created_at,
         git_revision: git_revision,
         baseline_run_id: baseline_run_id,
         control_run_ids: control_run_ids,
         source_run_ids: source_run_ids,
         provenance: provenance,
         settings: settings,
         thresholds: thresholds
       }}
    end
  end

  def new(_attributes), do: {:error, Validation.error(__MODULE__, :attributes, :must_be_a_map)}

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = calibration) do
    case calibration |> Map.from_struct() |> new() do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = calibration) do
    %{
      "schema_version" => calibration.schema_version,
      "calibration_id" => calibration.calibration_id,
      "created_at" => DateTime.to_iso8601(calibration.created_at),
      "git_revision" => calibration.git_revision,
      "baseline_run_id" => calibration.baseline_run_id,
      "control_run_ids" => calibration.control_run_ids,
      "source_run_ids" => calibration.source_run_ids,
      "provenance" => calibration.provenance,
      "settings" => calibration.settings,
      "thresholds" => calibration.thresholds
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_schema_version(@schema_version), do: :ok

  defp validate_schema_version(version) do
    {:error,
     %{
       type: :unsupported_schema_version,
       source: __MODULE__,
       expected: @schema_version,
       actual: version
     }}
  end

  defp validate_control_run_ids(control_run_ids) do
    with :ok <- Validation.string_list(control_run_ids, :control_run_ids, __MODULE__) do
      cond do
        control_run_ids == [] ->
          {:error, Validation.error(__MODULE__, :control_run_ids, :must_be_a_non_empty_list)}

        Enum.uniq(control_run_ids) != control_run_ids ->
          {:error, Validation.error(__MODULE__, :control_run_ids, :must_be_unique)}

        true ->
          :ok
      end
    end
  end

  defp validate_source_run_ids(source_run_ids, baseline_run_id, control_run_ids) do
    with :ok <- Validation.string_list(source_run_ids, :source_run_ids, __MODULE__) do
      if source_run_ids == [baseline_run_id | control_run_ids] do
        :ok
      else
        {:error,
         Validation.error(
           __MODULE__,
           :source_run_ids,
           :must_equal_baseline_followed_by_controls
         )}
      end
    end
  end

  defp validate_thresholds(thresholds, provenance) do
    with :ok <- Validation.json_object_list(thresholds, :thresholds, __MODULE__) do
      expected_case_ids = Enum.map(Map.get(provenance, "cases", []), & &1["id"])
      actual_case_ids = Enum.map(thresholds, & &1["case_id"])

      cond do
        thresholds == [] ->
          {:error, Validation.error(__MODULE__, :thresholds, :must_be_a_non_empty_list)}

        actual_case_ids != expected_case_ids ->
          {:error, Validation.error(__MODULE__, :thresholds, :must_match_provenance_cases)}

        not (Enum.zip_with(thresholds, provenance["cases"], &valid_threshold?/2)
             |> Enum.all?()) ->
          {:error, Validation.error(__MODULE__, :thresholds, :invalid_threshold)}

        true ->
          :ok
      end
    end
  end

  defp validate_provenance(provenance) do
    with :ok <- Validation.json_object(provenance, :provenance, __MODULE__) do
      cases = provenance["cases"]

      if non_empty_string?(provenance["provider"]) and is_map(provenance["request_config"]) and
           is_list(provenance["returned_models"]) and provenance["returned_models"] != [] and
           Enum.all?(provenance["returned_models"], &non_empty_string?/1) and is_list(cases) and
           cases != [] and Enum.all?(cases, &valid_case_summary?/1) do
        :ok
      else
        {:error, Validation.error(__MODULE__, :provenance, :invalid_provenance)}
      end
    end
  end

  defp validate_settings(settings) do
    with :ok <- Validation.json_object(settings, :settings, __MODULE__) do
      if is_integer(settings["seed"]) and positive_integer?(settings["iterations"]) and
           probability?(settings["quantile"]) and probability?(settings["adjusted_p_alpha"]) and
           positive_integer?(settings["baseline_group_size"]) and
           positive_integer?(settings["control_group_size"]) do
        :ok
      else
        {:error, Validation.error(__MODULE__, :settings, :invalid_settings)}
      end
    end
  end

  defp valid_threshold?(threshold, case_summary) do
    threshold["case_id"] == case_summary["id"] and
      threshold["case_fingerprint"] == case_summary["fingerprint"] and
      is_number(threshold["threshold"]) and
      is_list(threshold["null_energies"]) and threshold["null_energies"] != [] and
      Enum.all?(threshold["null_energies"], &is_number/1)
  end

  defp valid_case_summary?(summary) do
    is_map(summary) and non_empty_string?(summary["id"]) and
      positive_integer?(summary["version"]) and
      is_binary(summary["fingerprint"]) and
      String.match?(summary["fingerprint"], ~r/\A[0-9a-f]{64}\z/)
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp probability?(value), do: is_number(value) and value > 0 and value < 1
end
