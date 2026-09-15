defmodule SilentRegression.Baselines.BaselineMember do
  @moduledoc """
  Immutable membership of one exact observation in an approved baseline.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.Captures.CaptureObservation
  alias SilentRegression.Monitors.CaseVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "baseline_members" do
    field :position, :integer
    field :case_key, :string
    field :sample_index, :integer
    field :case_fingerprint, :string
    field :request_fingerprint, :string

    belongs_to :baseline_snapshot, BaselineSnapshot
    belongs_to :capture_observation, CaptureObservation
    belongs_to :case_version, CaseVersion

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def create_changeset(member, snapshot, observation, case_version, attrs) do
    member
    |> cast(attrs, [
      :position,
      :case_key,
      :sample_index,
      :case_fingerprint,
      :request_fingerprint
    ])
    |> put_change(:baseline_snapshot_id, snapshot.id)
    |> put_change(:capture_observation_id, observation.id)
    |> put_change(:case_version_id, case_version.id)
    |> validate_required([
      :position,
      :case_key,
      :sample_index,
      :case_fingerprint,
      :request_fingerprint,
      :baseline_snapshot_id,
      :capture_observation_id,
      :case_version_id
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:sample_index, greater_than_or_equal_to: 0)
    |> validate_length(:case_key, min: 2, max: 80)
    |> validate_format(:case_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:request_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> foreign_key_constraint(:baseline_snapshot_id)
    |> foreign_key_constraint(:capture_observation_id)
    |> foreign_key_constraint(:case_version_id)
    |> unique_constraint([:baseline_snapshot_id, :capture_observation_id])
    |> unique_constraint([:baseline_snapshot_id, :position])
    |> unique_constraint([:baseline_snapshot_id, :case_version_id, :sample_index],
      name: :baseline_members_snapshot_case_sample_index
    )
    |> check_constraint(:position, name: :baseline_members_position_check)
    |> check_constraint(:case_fingerprint, name: :baseline_members_fingerprints_check)
  end
end
