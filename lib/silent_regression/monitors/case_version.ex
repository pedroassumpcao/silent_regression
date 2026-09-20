defmodule SilentRegression.Monitors.CaseVersion do
  @moduledoc """
  Immutable case content captured inside one monitor-version snapshot.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.CaseExpectations
  alias SilentRegression.Monitors.MonitorVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:active, :disabled]

  schema "case_versions" do
    field :case_key, :string
    field :name, :string
    field :position, :integer
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :input_variables, :map, default: %{}
    field :frozen_context, :string, default: ""
    field :expectation_schema_version, :string, default: "no_case_expectation"
    field :expectation, :map, default: %{}
    field :expectation_fingerprint, :string
    field :fingerprint, :string

    belongs_to :monitor_version, MonitorVersion
    belongs_to :created_by_user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def create_changeset(case_version, %MonitorVersion{} = version, %User{} = user, attrs) do
    case_version
    |> cast(attrs, [
      :case_key,
      :name,
      :position,
      :status,
      :input_variables,
      :frozen_context,
      :expectation_schema_version,
      :expectation,
      :expectation_fingerprint,
      :fingerprint
    ])
    |> put_change(:monitor_version_id, version.id)
    |> put_change(:created_by_user_id, user.id)
    |> validate_required([
      :case_key,
      :name,
      :position,
      :status,
      :input_variables,
      :frozen_context,
      :expectation_schema_version,
      :expectation,
      :expectation_fingerprint,
      :fingerprint,
      :monitor_version_id,
      :created_by_user_id
    ])
    |> validate_length(:case_key, min: 2, max: 80)
    |> validate_format(:case_key, ~r/^[a-z0-9]+(?:[-_][a-z0-9]+)*$/)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_format(:fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_inclusion(:expectation_schema_version, [
      CaseExpectations.none_schema(),
      CaseExpectations.schema_version()
    ])
    |> validate_format(:expectation_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> foreign_key_constraint(:monitor_version_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:monitor_version_id, :case_key])
    |> unique_constraint([:monitor_version_id, :position])
    |> check_constraint(:position, name: :case_versions_position_check)
    |> check_constraint(:status, name: :case_versions_status_check)
    |> check_constraint(:fingerprint, name: :case_versions_fingerprint_check)
    |> check_constraint(:expectation, name: :case_versions_expectation_check)
  end

  def statuses, do: @statuses
end
