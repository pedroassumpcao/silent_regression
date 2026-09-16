defmodule SilentRegression.Repo.Migrations.CreateNotificationPreferencesAndDeliveries do
  use Ecto.Migration

  def change do
    create table(:notification_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actionable_alert_email_enabled, :boolean, null: false, default: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_preferences, [:workspace_id, :user_id])
    create index(:notification_preferences, [:user_id])

    create table(:notification_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :channel, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :outcome_reason, :string
      add :last_attempted_at, :utc_datetime_usec
      add :sent_at, :utc_datetime_usec

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :result_alert_id,
          references(:result_alerts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :recipient_user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_deliveries, [
             :result_alert_id,
             :recipient_user_id,
             :channel
           ])

    create index(:notification_deliveries, [:workspace_id, :status, :inserted_at])
    create index(:notification_deliveries, [:recipient_user_id, :inserted_at])

    create constraint(:notification_deliveries, :notification_deliveries_kind_check,
             check: "kind = 'actionable_alert'"
           )

    create constraint(:notification_deliveries, :notification_deliveries_channel_check,
             check: "channel = 'email'"
           )

    create constraint(:notification_deliveries, :notification_deliveries_status_check,
             check: "status IN ('pending', 'sent', 'failed', 'skipped')"
           )

    create constraint(:notification_deliveries, :notification_deliveries_attempts_check,
             check: "attempts >= 0 AND attempts <= 5"
           )

    create constraint(:notification_deliveries, :notification_deliveries_outcome_reason_check,
             check:
               "outcome_reason IS NULL OR outcome_reason IN ('adapter_error', 'preference_disabled', 'recipient_unavailable')"
           )

    create constraint(:notification_deliveries, :notification_deliveries_lifecycle_check,
             check: """
             (status = 'pending' AND sent_at IS NULL AND outcome_reason IS NULL) OR
             (status = 'sent' AND attempts >= 1 AND sent_at IS NOT NULL AND outcome_reason IS NULL) OR
             (status = 'failed' AND attempts >= 1 AND sent_at IS NULL AND outcome_reason = 'adapter_error') OR
             (status = 'skipped' AND sent_at IS NULL AND outcome_reason IN ('preference_disabled', 'recipient_unavailable'))
             """
           )

    execute(
      """
      CREATE FUNCTION protect_notification_delivery_identity()
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
      """,
      "DROP FUNCTION IF EXISTS protect_notification_delivery_identity()"
    )

    execute(
      """
      CREATE TRIGGER notification_deliveries_identity_guard
      BEFORE UPDATE ON notification_deliveries
      FOR EACH ROW EXECUTE FUNCTION protect_notification_delivery_identity();
      """,
      "DROP TRIGGER IF EXISTS notification_deliveries_identity_guard ON notification_deliveries"
    )
  end
end
