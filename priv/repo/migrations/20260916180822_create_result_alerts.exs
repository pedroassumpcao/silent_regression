defmodule SilentRegression.Repo.Migrations.CreateResultAlerts do
  use Ecto.Migration

  def change do
    create table(:result_alerts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identity_key, :string, null: false
      add :category, :string, null: false
      add :severity, :string, null: false
      add :status, :string, null: false, default: "open"
      add :code, :string, null: false
      add :title, :string, null: false
      add :explanation, :text, null: false
      add :evidence, :map, null: false, default: %{}
      add :notification_state, :string, null: false, default: "not_configured"
      add :opened_at, :utc_datetime_usec, null: false
      add :acknowledged_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_evaluation_id,
          references(:capture_evaluations, type: :binary_id, on_delete: :delete_all)

      add :acknowledged_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :resolved_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:result_alerts, [:workspace_id, :identity_key])
    create index(:result_alerts, [:workspace_id, :status, :opened_at])
    create index(:result_alerts, [:monitor_id, :status, :opened_at])
    create index(:result_alerts, [:capture_run_id])
    create index(:result_alerts, [:capture_evaluation_id])

    create constraint(:result_alerts, :result_alerts_category_check,
             check: "category IN ('contract_failure', 'operational_anomaly')"
           )

    create constraint(:result_alerts, :result_alerts_severity_check,
             check: "severity IN ('critical', 'warning')"
           )

    create constraint(:result_alerts, :result_alerts_status_check,
             check: "status IN ('open', 'acknowledged', 'resolved')"
           )

    create constraint(:result_alerts, :result_alerts_notification_state_check,
             check: "notification_state IN ('not_configured', 'pending', 'sent', 'failed')"
           )

    create constraint(:result_alerts, :result_alerts_lifecycle_check,
             check: """
             (status = 'open' AND acknowledged_at IS NULL AND acknowledged_by_user_id IS NULL AND
               resolved_at IS NULL AND resolved_by_user_id IS NULL) OR
             (status = 'acknowledged' AND acknowledged_at IS NOT NULL AND
               acknowledged_by_user_id IS NOT NULL AND resolved_at IS NULL AND
               resolved_by_user_id IS NULL) OR
             (status = 'resolved' AND acknowledged_at IS NOT NULL AND
               acknowledged_by_user_id IS NOT NULL AND resolved_at IS NOT NULL AND
               resolved_by_user_id IS NOT NULL)
             """
           )

    execute(
      """
      CREATE FUNCTION protect_result_alert()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.identity_key, NEW.category, NEW.severity, NEW.code, NEW.title,
          NEW.explanation, NEW.evidence, NEW.opened_at, NEW.workspace_id, NEW.monitor_id,
          NEW.capture_run_id, NEW.capture_evaluation_id
        ) IS DISTINCT FROM ROW(
          OLD.identity_key, OLD.category, OLD.severity, OLD.code, OLD.title,
          OLD.explanation, OLD.evidence, OLD.opened_at, OLD.workspace_id, OLD.monitor_id,
          OLD.capture_run_id, OLD.capture_evaluation_id
        ) THEN
          RAISE EXCEPTION 'result alert evidence is immutable' USING ERRCODE = '23514';
        END IF;

        IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'acknowledged') THEN
          RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
        ELSIF OLD.status = 'acknowledged' AND NEW.status NOT IN ('acknowledged', 'resolved') THEN
          RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
        ELSIF OLD.status = 'resolved' AND NEW.status <> 'resolved' THEN
          RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS protect_result_alert()"
    )

    execute(
      """
      CREATE TRIGGER result_alerts_guard
      BEFORE UPDATE ON result_alerts
      FOR EACH ROW EXECUTE FUNCTION protect_result_alert();
      """,
      "DROP TRIGGER IF EXISTS result_alerts_guard ON result_alerts"
    )
  end
end
