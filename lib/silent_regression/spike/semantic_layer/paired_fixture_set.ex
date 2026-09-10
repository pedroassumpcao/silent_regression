defmodule SilentRegression.Spike.SemanticLayer.PairedFixtureSet do
  @moduledoc """
  Versioned contract for diversity-matched semantic fixture derivatives.

  A parent observation belongs to exactly one partition, and a batch cannot
  reuse the same parent for the same semantic label. Stored duplicate counts
  are validated against the output texts instead of trusted as annotations.
  """

  alias SilentRegression.Spike.SemanticLayer.ArtifactValidation
  alias SilentRegression.Spike.Validation

  @schema_version 1
  @artifact_type "semantic_paired_fixture_set"
  @statuses ~w(candidate approved)
  @splits ~w(authoring tuning heldout)
  @labels ~w(meaning_preserving style_only subtle_regression obvious_regression)
  @required_labels ~w(meaning_preserving style_only subtle_regression)
  @fields [
    :schema_version,
    :artifact_type,
    :fixture_set_id,
    :created_at,
    :git_revision,
    :status,
    :source_control,
    :partition_policy,
    :fixtures,
    :duplicate_counts
  ]

  @enforce_keys @fields -- [:git_revision]
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          artifact_type: String.t(),
          fixture_set_id: String.t(),
          created_at: DateTime.t(),
          git_revision: String.t() | nil,
          status: String.t(),
          source_control: map(),
          partition_policy: map(),
          fixtures: [map()],
          duplicate_counts: [map()]
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec artifact_type() :: String.t()
  def artifact_type, do: @artifact_type

  @spec splits() :: [String.t()]
  def splits, do: @splits

  @spec labels() :: [String.t()]
  def labels, do: @labels

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
         {:ok, fixture_set_id} <- required(attributes, :fixture_set_id),
         :ok <- Validation.non_empty_string(fixture_set_id, :fixture_set_id, __MODULE__),
         {:ok, created_at_value} <- required(attributes, :created_at),
         {:ok, created_at} <- Validation.parse_datetime(created_at_value, :created_at, __MODULE__),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, status} <- required(attributes, :status),
         :ok <- ArtifactValidation.enum(status, @statuses, :status, __MODULE__),
         {:ok, source_control} <- required(attributes, :source_control),
         :ok <- validate_source_control(source_control),
         {:ok, partition_policy} <- required(attributes, :partition_policy),
         :ok <- validate_partition_policy(partition_policy),
         {:ok, fixtures} <- required(attributes, :fixtures),
         :ok <- validate_fixtures(fixtures, source_control, status),
         {:ok, duplicate_counts} <- required(attributes, :duplicate_counts),
         :ok <- validate_duplicate_counts(duplicate_counts, fixtures) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         artifact_type: artifact_type,
         fixture_set_id: fixture_set_id,
         created_at: created_at,
         git_revision: git_revision,
         status: status,
         source_control: source_control,
         partition_policy: partition_policy,
         fixtures: fixtures,
         duplicate_counts: duplicate_counts
       }}
    end
  end

  def new(_attributes), do: validation_error(:attributes, :must_be_a_map)

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = fixture_set) do
    case fixture_set |> Map.from_struct() |> new() do
      {:ok, _fixture_set} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = fixture_set) do
    %{
      "schema_version" => fixture_set.schema_version,
      "artifact_type" => fixture_set.artifact_type,
      "fixture_set_id" => fixture_set.fixture_set_id,
      "created_at" => DateTime.to_iso8601(fixture_set.created_at),
      "git_revision" => fixture_set.git_revision,
      "status" => fixture_set.status,
      "source_control" => fixture_set.source_control,
      "partition_policy" => fixture_set.partition_policy,
      "fixtures" => fixture_set.fixtures,
      "duplicate_counts" => fixture_set.duplicate_counts
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  @spec duplicate_counts([map()]) :: [map()]
  def duplicate_counts(fixtures) when is_list(fixtures) do
    fixtures
    |> Enum.group_by(&{&1["split"], &1["label"]})
    |> Enum.map(fn {{split, label}, batch} ->
      sample_count = length(batch)

      unique_output_count =
        batch |> Enum.map(& &1["output_text"]) |> MapSet.new() |> MapSet.size()

      %{
        "split" => split,
        "label" => label,
        "sample_count" => sample_count,
        "unique_parent_count" =>
          batch |> Enum.map(& &1["parent_observation_id"]) |> MapSet.new() |> MapSet.size(),
        "unique_output_count" => unique_output_count,
        "duplicate_output_count" => sample_count - unique_output_count
      }
    end)
    |> Enum.sort_by(&{split_index(&1["split"]), label_index(&1["label"])})
  end

  defp validate_source_control(source_control) do
    keys = ~w(run_id condition artifact_sha256 case_id)

    with :ok <-
           ArtifactValidation.exact_json_keys(source_control, keys, :source_control, __MODULE__),
         :ok <- Validation.non_empty_string(source_control["run_id"], :source_control, __MODULE__),
         :ok <- validate_control_condition(source_control["condition"]),
         :ok <-
           ArtifactValidation.sha256(
             source_control["artifact_sha256"],
             :source_control,
             __MODULE__
           ),
         :ok <-
           Validation.non_empty_string(source_control["case_id"], :source_control, __MODULE__) do
      :ok
    end
  end

  defp validate_control_condition("control"), do: :ok

  defp validate_control_condition(_condition),
    do: validation_error(:source_control, :must_be_control)

  defp validate_partition_policy(partition_policy) do
    keys = ~w(version group_key splits)

    with :ok <-
           ArtifactValidation.exact_json_keys(
             partition_policy,
             keys,
             :partition_policy,
             __MODULE__
           ) do
      if partition_policy == %{
           "version" => 1,
           "group_key" => "parent_observation_id",
           "splits" => @splits
         },
         do: :ok,
         else: validation_error(:partition_policy, :unsupported_partition_policy)
    end
  end

  defp validate_fixtures(fixtures, source_control, status) do
    with :ok <- Validation.json_object_list(fixtures, :fixtures, __MODULE__) do
      cond do
        fixtures == [] ->
          validation_error(:fixtures, :must_be_a_non_empty_list)

        not Enum.all?(fixtures, &valid_fixture?(&1, source_control["case_id"])) ->
          validation_error(:fixtures, :contains_invalid_fixture)

        fixtures |> Enum.map(& &1["fixture_id"]) |> Enum.uniq() !=
            Enum.map(fixtures, & &1["fixture_id"]) ->
          validation_error(:fixtures, :fixture_ids_must_be_unique)

        fixtures |> Enum.map(&{&1["parent_observation_id"], &1["label"]}) |> Enum.uniq() !=
            Enum.map(fixtures, &{&1["parent_observation_id"], &1["label"]}) ->
          validation_error(:fixtures, :parent_label_pairs_must_be_unique)

        parent_crosses_partitions?(fixtures) ->
          validation_error(:fixtures, :parent_observation_must_belong_to_one_split)

        not parent_provenance_consistent?(fixtures) ->
          validation_error(:fixtures, :parent_observation_provenance_must_be_consistent)

        not parents_have_required_labels?(fixtures) ->
          validation_error(:fixtures, :each_parent_must_have_required_labels)

        status == "approved" and
            not Enum.all?(fixtures, &(get_in(&1, ["approval", "status"]) == "approved")) ->
          validation_error(:fixtures, :approved_set_requires_approved_fixtures)

        true ->
          :ok
      end
    end
  end

  defp valid_fixture?(fixture, case_id) do
    keys =
      ~w(fixture_id parent_observation_id parent_sample_index parent_output_sha256 case_id split label output_text approval)

    ArtifactValidation.exact_json_keys(fixture, keys, :fixtures, __MODULE__) == :ok and
      non_empty_string?(fixture["fixture_id"]) and
      non_empty_string?(fixture["parent_observation_id"]) and
      is_integer(fixture["parent_sample_index"]) and fixture["parent_sample_index"] >= 0 and
      valid_sha256?(fixture["parent_output_sha256"]) and fixture["case_id"] == case_id and
      fixture["split"] in @splits and fixture["label"] in @labels and
      non_empty_string?(fixture["output_text"]) and valid_approval?(fixture["approval"])
  end

  defp valid_approval?(approval) do
    keys = ~w(status reviewer reviewed_at)

    ArtifactValidation.exact_json_keys(approval, keys, :fixtures, __MODULE__) == :ok and
      case approval["status"] do
        "candidate" ->
          is_nil(approval["reviewer"]) and is_nil(approval["reviewed_at"])

        "approved" ->
          non_empty_string?(approval["reviewer"]) and iso8601?(approval["reviewed_at"])

        _status ->
          false
      end
  end

  defp parent_crosses_partitions?(fixtures) do
    fixtures
    |> Enum.group_by(& &1["parent_observation_id"], & &1["split"])
    |> Enum.any?(fn {_parent, splits} -> length(Enum.uniq(splits)) != 1 end)
  end

  defp parent_provenance_consistent?(fixtures) do
    fixtures
    |> Enum.group_by(& &1["parent_observation_id"])
    |> Enum.all?(fn {_parent, derivatives} ->
      derivatives
      |> Enum.map(&{&1["parent_sample_index"], &1["parent_output_sha256"], &1["case_id"]})
      |> Enum.uniq()
      |> length() == 1
    end)
  end

  defp parents_have_required_labels?(fixtures) do
    fixtures
    |> Enum.group_by(& &1["parent_observation_id"], & &1["label"])
    |> Enum.all?(fn {_parent, labels} ->
      Enum.all?(@required_labels, &(&1 in labels))
    end)
  end

  defp validate_duplicate_counts(duplicate_counts, fixtures) do
    with :ok <- Validation.json_object_list(duplicate_counts, :duplicate_counts, __MODULE__) do
      if duplicate_counts == duplicate_counts(fixtures),
        do: :ok,
        else: validation_error(:duplicate_counts, :must_match_fixture_outputs)
    end
  end

  defp required(attributes, field), do: Validation.fetch_required(attributes, field, __MODULE__)

  defp validation_error(field, reason),
    do: {:error, ArtifactValidation.error(__MODULE__, field, reason)}

  defp split_index(split), do: Enum.find_index(@splits, &(&1 == split))
  defp label_index(label), do: Enum.find_index(@labels, &(&1 == label))
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp iso8601?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp iso8601?(_value), do: false
end
