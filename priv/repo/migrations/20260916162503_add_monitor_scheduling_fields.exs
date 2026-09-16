defmodule SilentRegression.Repo.Migrations.AddMonitorSchedulingFields do
  use Ecto.Migration

  def change do
    alter table(:monitors) do
      add :cadence, :string, null: false, default: "manual"
      add :next_run_at, :utc_datetime
      add :last_scheduled_at, :utc_datetime
      add :schedule_updated_at, :utc_datetime
      add :pause_reason, :string

      add :schedule_updated_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:monitors, [:schedule_updated_by_user_id])
    create index(:monitors, [:state, :next_run_at])

    create constraint(:monitors, :monitors_cadence_check,
             check: "cadence IN ('manual', 'daily', 'weekly')"
           )

    create constraint(:monitors, :monitors_pause_reason_check,
             check:
               "pause_reason IS NULL OR pause_reason IN ('owner_paused', 'credential_unavailable', 'incompatible_configuration', 'repeated_authentication_failures', 'workspace_call_limit', 'schedule_owner_unavailable')"
           )

    create constraint(:monitors, :monitors_manual_schedule_check,
             check: "cadence <> 'manual' OR next_run_at IS NULL"
           )

    create constraint(:monitors, :monitors_paused_schedule_check,
             check: "state <> 'paused' OR next_run_at IS NULL"
           )
  end
end
