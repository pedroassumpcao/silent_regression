defmodule SilentRegression.Repo.Migrations.CreateOperationalControls do
  use Ecto.Migration

  def up do
    create table(:operational_heartbeats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false
      add :observed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operational_heartbeats, [:name])

    create constraint(:operational_heartbeats, :operational_heartbeats_name_check,
             check: "name IN ('scheduler_dispatch', 'workspace_purge')"
           )

    create constraint(:operational_heartbeats, :operational_heartbeats_status_check,
             check: "status IN ('ok', 'error')"
           )

    create table(:operational_drills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :environment, :string, null: false
      add :release_sha, :string, null: false
      add :outcome, :string, null: false
      add :operator_identifier, :string, null: false
      add :evidence_ref, :string, null: false
      add :performed_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:operational_drills, [:environment, :kind, :performed_at])

    create constraint(:operational_drills, :operational_drills_kind_check,
             check:
               "kind IN ('backup_restore', 'rollback', 'key_rotation', 'deletion_reconciliation', 'incident_response')"
           )

    create constraint(:operational_drills, :operational_drills_outcome_check,
             check: "outcome IN ('passed', 'failed')"
           )

    create constraint(:operational_drills, :operational_drills_lifecycle_check,
             check: "expires_at > performed_at"
           )
  end

  def down do
    drop table(:operational_drills)
    drop table(:operational_heartbeats)
  end
end
