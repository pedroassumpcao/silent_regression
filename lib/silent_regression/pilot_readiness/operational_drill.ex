defmodule SilentRegression.PilotReadiness.OperationalDrill do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @kinds [
    :backup_restore,
    :rollback,
    :key_rotation,
    :deletion_reconciliation,
    :incident_response
  ]
  @outcomes [:passed, :failed]

  schema "operational_drills" do
    field :kind, Ecto.Enum, values: @kinds
    field :environment, :string
    field :release_sha, :string
    field :outcome, Ecto.Enum, values: @outcomes
    field :operator_identifier, :string
    field :evidence_ref, :string
    field :performed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(drill, attrs) do
    drill
    |> cast(attrs, [
      :kind,
      :environment,
      :release_sha,
      :outcome,
      :operator_identifier,
      :evidence_ref,
      :performed_at,
      :expires_at
    ])
    |> validate_required([
      :kind,
      :environment,
      :release_sha,
      :outcome,
      :operator_identifier,
      :evidence_ref,
      :performed_at,
      :expires_at
    ])
    |> validate_length(:environment, min: 2, max: 80)
    |> validate_format(:environment, ~r/^[a-z0-9][a-z0-9_-]+$/)
    |> validate_length(:release_sha, min: 7, max: 64)
    |> validate_format(:release_sha, ~r/^[A-Za-z0-9._-]+$/)
    |> validate_length(:operator_identifier, min: 2, max: 160)
    |> validate_format(:operator_identifier, ~r/^[A-Za-z0-9][A-Za-z0-9@._+-]+$/)
    |> validate_length(:evidence_ref, min: 3, max: 300)
    |> validate_format(:evidence_ref, ~r|^[A-Za-z0-9][A-Za-z0-9._:/#-]+$|)
    |> validate_expiry()
    |> check_constraint(:kind, name: :operational_drills_kind_check)
    |> check_constraint(:outcome, name: :operational_drills_outcome_check)
    |> check_constraint(:expires_at, name: :operational_drills_lifecycle_check)
  end

  def kinds, do: @kinds

  defp validate_expiry(changeset) do
    performed_at = get_field(changeset, :performed_at)
    expires_at = get_field(changeset, :expires_at)

    if performed_at && expires_at && DateTime.after?(expires_at, performed_at) do
      changeset
    else
      add_error(changeset, :expires_at, "must be after the drill time")
    end
  end
end
