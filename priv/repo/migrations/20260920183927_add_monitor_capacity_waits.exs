defmodule SilentRegression.Repo.Migrations.AddMonitorCapacityWaits do
  use Ecto.Migration

  def up do
    alter table(:monitors) do
      add :capacity_wait_reason, :string
      add :capacity_retry_at, :utc_datetime
      add :capacity_intended_at, :utc_datetime
      add :coverage_interrupted_at, :utc_datetime
    end

    create index(:monitors, [:capacity_retry_at],
             where: "capacity_wait_reason IS NOT NULL",
             name: :monitors_capacity_retry_at_index
           )

    create constraint(:monitors, :monitors_capacity_wait_check,
             check: """
             (
               capacity_wait_reason IS NULL AND capacity_retry_at IS NULL AND
               capacity_intended_at IS NULL AND coverage_interrupted_at IS NULL
             ) OR (
               capacity_wait_reason IN ('workspace_run_limit', 'workspace_call_limit') AND
               capacity_retry_at IS NOT NULL AND capacity_intended_at IS NOT NULL AND
               coverage_interrupted_at IS NOT NULL AND state = 'active' AND
               cadence IN ('daily', 'weekly') AND next_run_at = capacity_retry_at
             )
             """
           )

    drop constraint(:monitors, :monitors_pause_reason_check)

    create constraint(:monitors, :monitors_pause_reason_check,
             check: """
             pause_reason IS NULL OR pause_reason IN (
               'owner_paused', 'credential_unavailable', 'incompatible_configuration',
               'repeated_authentication_failures', 'workspace_call_limit',
               'workspace_run_limit', 'per_run_call_limit', 'schedule_owner_unavailable',
               'workspace_closed'
             )
             """
           )

    alter table(:notification_deliveries) do
      modify :result_alert_id, :binary_id, null: true

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all)

      add :deduplication_key, :string
      add :coverage_reason, :string
      add :coverage_retry_at, :utc_datetime_usec
      add :coverage_intended_at, :utc_datetime_usec
    end

    create index(:notification_deliveries, [:monitor_id, :inserted_at])

    create unique_index(
             :notification_deliveries,
             [:deduplication_key, :recipient_user_id, :channel],
             where: "deduplication_key IS NOT NULL",
             name: :notification_deliveries_deduplication_key_index
           )

    drop constraint(:notification_deliveries, :notification_deliveries_kind_check)

    create constraint(:notification_deliveries, :notification_deliveries_kind_check,
             check: "kind IN ('actionable_alert', 'coverage_interrupted')"
           )

    create constraint(:notification_deliveries, :notification_deliveries_subject_check,
             check: """
             (
               kind = 'actionable_alert' AND result_alert_id IS NOT NULL AND
               monitor_id IS NULL AND deduplication_key IS NULL AND coverage_reason IS NULL AND
               coverage_retry_at IS NULL AND coverage_intended_at IS NULL
             ) OR (
               kind = 'coverage_interrupted' AND result_alert_id IS NULL AND
               monitor_id IS NOT NULL AND deduplication_key IS NOT NULL AND
               coverage_reason IN ('workspace_run_limit', 'workspace_call_limit') AND
               coverage_retry_at IS NOT NULL AND coverage_intended_at IS NOT NULL
             )
             """
           )

    create constraint(:notification_deliveries, :notification_deliveries_deduplication_key_check,
             check:
               "deduplication_key IS NULL OR char_length(deduplication_key) BETWEEN 1 AND 200"
           )

    execute("""
    CREATE OR REPLACE FUNCTION protect_notification_delivery_identity()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.kind, NEW.channel, NEW.workspace_id, NEW.result_alert_id, NEW.monitor_id,
        NEW.deduplication_key, NEW.coverage_reason, NEW.coverage_retry_at,
        NEW.coverage_intended_at, NEW.recipient_user_id
      ) IS DISTINCT FROM ROW(
        OLD.kind, OLD.channel, OLD.workspace_id, OLD.result_alert_id, OLD.monitor_id,
        OLD.deduplication_key, OLD.coverage_reason, OLD.coverage_retry_at,
        OLD.coverage_intended_at, OLD.recipient_user_id
      ) THEN
        RAISE EXCEPTION 'notification delivery identity is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("DELETE FROM notification_deliveries WHERE kind = 'coverage_interrupted'")

    drop constraint(:notification_deliveries, :notification_deliveries_subject_check)
    drop constraint(:notification_deliveries, :notification_deliveries_deduplication_key_check)
    drop constraint(:notification_deliveries, :notification_deliveries_kind_check)

    create constraint(:notification_deliveries, :notification_deliveries_kind_check,
             check: "kind = 'actionable_alert'"
           )

    drop_if_exists index(
                     :notification_deliveries,
                     [:deduplication_key, :recipient_user_id, :channel],
                     name: :notification_deliveries_deduplication_key_index
                   )

    drop_if_exists index(:notification_deliveries, [:monitor_id, :inserted_at])

    execute("""
    CREATE OR REPLACE FUNCTION protect_notification_delivery_identity()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.kind, NEW.channel, NEW.workspace_id, NEW.result_alert_id, NEW.recipient_user_id
      ) IS DISTINCT FROM ROW(
        OLD.kind, OLD.channel, OLD.workspace_id, OLD.result_alert_id, OLD.recipient_user_id
      ) THEN
        RAISE EXCEPTION 'notification delivery identity is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    alter table(:notification_deliveries) do
      remove :coverage_intended_at
      remove :coverage_retry_at
      remove :coverage_reason
      remove :deduplication_key
      remove :monitor_id

      modify :result_alert_id, :binary_id, null: false
    end

    execute(
      "UPDATE monitors SET pause_reason = 'incompatible_configuration' WHERE pause_reason = 'per_run_call_limit'"
    )

    drop constraint(:monitors, :monitors_pause_reason_check)

    create constraint(:monitors, :monitors_pause_reason_check,
             check: """
             pause_reason IS NULL OR pause_reason IN (
               'owner_paused', 'credential_unavailable', 'incompatible_configuration',
               'repeated_authentication_failures', 'workspace_call_limit',
               'workspace_run_limit', 'schedule_owner_unavailable', 'workspace_closed'
             )
             """
           )

    drop constraint(:monitors, :monitors_capacity_wait_check)
    drop_if_exists index(:monitors, [:capacity_retry_at], name: :monitors_capacity_retry_at_index)

    alter table(:monitors) do
      remove :coverage_interrupted_at
      remove :capacity_intended_at
      remove :capacity_retry_at
      remove :capacity_wait_reason
    end
  end
end
