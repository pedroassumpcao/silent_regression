defmodule SilentRegression.Repo.Migrations.CreateIncidentsAndOccurrences do
  use Ecto.Migration

  def up do
    create table(:result_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :signature, :string, null: false
      add :signature_schema_version, :string, null: false
      add :signature_components, :map, null: false, default: %{}
      add :episode, :integer, null: false
      add :category, :string, null: false
      add :severity, :string, null: false
      add :status, :string, null: false, default: "open"
      add :code, :string, null: false
      add :title, :string, null: false
      add :explanation, :text, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :occurrence_count, :integer, null: false, default: 1
      add :run_count, :integer, null: false, default: 1
      add :affected_case_count, :integer, null: false, default: 0
      add :acknowledged_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :recovered_at, :utc_datetime_usec

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_version_id,
          references(:monitor_versions, type: :binary_id),
          null: false

      add :reopened_from_id, references(:result_incidents, type: :binary_id)
      add :acknowledged_by_user_id, references(:users, type: :binary_id)
      add :resolved_by_user_id, references(:users, type: :binary_id)

      add :resolution_review_decision_id,
          references(:review_decisions, type: :binary_id)

      add :recovery_capture_run_id, references(:capture_runs, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:result_incidents, [:workspace_id, :signature, :episode])

    create unique_index(:result_incidents, [:workspace_id, :signature],
             where: "status IN ('open', 'acknowledged')",
             name: :result_incidents_one_active_signature_index
           )

    create index(:result_incidents, [:workspace_id, :status, :last_seen_at])
    create index(:result_incidents, [:monitor_id, :status, :last_seen_at])
    create index(:result_incidents, [:monitor_version_id, :status])
    create index(:result_incidents, [:reopened_from_id])

    create constraint(:result_incidents, :result_incidents_category_check,
             check:
               "category IN ('contract_failure', 'case_expectation_failure', 'operational_anomaly')"
           )

    create constraint(:result_incidents, :result_incidents_severity_check,
             check: "severity IN ('critical', 'warning')"
           )

    create constraint(:result_incidents, :result_incidents_status_check,
             check: "status IN ('open', 'acknowledged', 'resolved', 'recovered')"
           )

    create constraint(:result_incidents, :result_incidents_counts_check,
             check:
               "episode > 0 AND occurrence_count > 0 AND run_count > 0 AND affected_case_count >= 0 AND run_count <= occurrence_count"
           )

    create constraint(:result_incidents, :result_incidents_signature_check,
             check:
               "char_length(signature) BETWEEN 1 AND 200 AND char_length(signature_schema_version) BETWEEN 1 AND 80"
           )

    create constraint(:result_incidents, :result_incidents_lifecycle_check,
             check: """
             (
               status = 'open' AND acknowledged_at IS NULL AND acknowledged_by_user_id IS NULL AND
               resolved_at IS NULL AND resolved_by_user_id IS NULL AND
               resolution_review_decision_id IS NULL AND recovered_at IS NULL AND
               recovery_capture_run_id IS NULL
             ) OR (
               status = 'acknowledged' AND acknowledged_at IS NOT NULL AND
               acknowledged_by_user_id IS NOT NULL AND resolved_at IS NULL AND
               resolved_by_user_id IS NULL AND resolution_review_decision_id IS NULL AND
               recovered_at IS NULL AND recovery_capture_run_id IS NULL
             ) OR (
               status = 'resolved' AND acknowledged_at IS NOT NULL AND
               acknowledged_by_user_id IS NOT NULL AND resolved_at IS NOT NULL AND
               resolved_by_user_id IS NOT NULL AND resolution_review_decision_id IS NOT NULL AND
               recovered_at IS NULL AND recovery_capture_run_id IS NULL
             ) OR (
               status = 'recovered' AND resolved_at IS NULL AND resolved_by_user_id IS NULL AND
               resolution_review_decision_id IS NULL AND recovered_at IS NOT NULL AND
               recovery_capture_run_id IS NOT NULL AND
               ((acknowledged_at IS NULL AND acknowledged_by_user_id IS NULL) OR
                (acknowledged_at IS NOT NULL AND acknowledged_by_user_id IS NOT NULL))
             )
             """
           )

    create table(:result_incident_occurrences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ordinal, :integer, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :case_fingerprints, {:array, :string}, null: false, default: []
      add :exceptional_reference, :boolean, null: false, default: false

      add :result_incident_id,
          references(:result_incidents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :result_alert_id,
          references(:result_alerts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:result_incident_occurrences, [:result_alert_id])
    create unique_index(:result_incident_occurrences, [:result_incident_id, :ordinal])

    create unique_index(:result_incident_occurrences, [:result_incident_id, :capture_run_id],
             name: :incident_occurrences_incident_run_index
           )

    create index(:result_incident_occurrences, [:capture_run_id])

    create constraint(:result_incident_occurrences, :result_incident_occurrences_ordinal_check,
             check: "ordinal > 0"
           )

    create_incident_guard()
    backfill_legacy_alerts()
    expand_notification_deliveries()
  end

  def down do
    execute("DELETE FROM notification_deliveries WHERE result_incident_id IS NOT NULL")
    restore_notification_deliveries()
    execute("DROP TRIGGER IF EXISTS result_incidents_guard ON result_incidents")
    execute("DROP FUNCTION IF EXISTS protect_result_incident()")
    drop table(:result_incident_occurrences)
    drop table(:result_incidents)
  end

  defp create_incident_guard do
    execute("""
    CREATE FUNCTION protect_result_incident()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.signature, NEW.signature_schema_version, NEW.signature_components, NEW.episode,
        NEW.category, NEW.severity, NEW.code, NEW.title, NEW.explanation, NEW.first_seen_at,
        NEW.workspace_id, NEW.monitor_id, NEW.monitor_version_id, NEW.reopened_from_id
      ) IS DISTINCT FROM ROW(
        OLD.signature, OLD.signature_schema_version, OLD.signature_components, OLD.episode,
        OLD.category, OLD.severity, OLD.code, OLD.title, OLD.explanation, OLD.first_seen_at,
        OLD.workspace_id, OLD.monitor_id, OLD.monitor_version_id, OLD.reopened_from_id
      ) THEN
        RAISE EXCEPTION 'result incident identity is immutable' USING ERRCODE = '23514';
      END IF;

      IF NEW.occurrence_count < OLD.occurrence_count OR NEW.run_count < OLD.run_count OR
         NEW.affected_case_count < OLD.affected_case_count OR NEW.last_seen_at < OLD.last_seen_at THEN
        RAISE EXCEPTION 'result incident history cannot move backward' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'acknowledged', 'recovered') THEN
        RAISE EXCEPTION 'invalid result incident lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'acknowledged' AND NEW.status NOT IN ('acknowledged', 'resolved', 'recovered') THEN
        RAISE EXCEPTION 'invalid result incident lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status IN ('resolved', 'recovered') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'invalid result incident lifecycle transition' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER result_incidents_guard
    BEFORE UPDATE ON result_incidents
    FOR EACH ROW EXECUTE FUNCTION protect_result_incident();
    """)
  end

  defp backfill_legacy_alerts do
    execute("""
    INSERT INTO result_incidents (
      id, signature, signature_schema_version, signature_components, episode,
      category, severity, status, code, title, explanation, first_seen_at, last_seen_at,
      occurrence_count, run_count, affected_case_count, workspace_id, monitor_id,
      monitor_version_id, acknowledged_by_user_id, acknowledged_at, resolved_by_user_id,
      resolved_at, resolution_review_decision_id, inserted_at, updated_at
    )
    SELECT
      gen_random_uuid(), 'legacy-alert-v1:' || alert.id::text, 'legacy_alert_identity_v1',
      jsonb_build_object('result_alert_id', alert.id::text), 1,
      alert.category, alert.severity, alert.status, alert.code, alert.title, alert.explanation,
      alert.opened_at, alert.opened_at, 1, 1, 0, alert.workspace_id, alert.monitor_id,
      run.monitor_version_id, alert.acknowledged_by_user_id, alert.acknowledged_at,
      alert.resolved_by_user_id, alert.resolved_at, alert.resolution_review_decision_id,
      alert.inserted_at, alert.updated_at
    FROM result_alerts alert
    JOIN capture_runs run ON run.id = alert.capture_run_id
    """)

    execute("""
    INSERT INTO result_incident_occurrences (
      id, ordinal, occurred_at, case_fingerprints, exceptional_reference,
      result_incident_id, result_alert_id, capture_run_id, inserted_at
    )
    SELECT
      gen_random_uuid(), 1, alert.opened_at, ARRAY[]::varchar[],
      COALESCE(baseline.approval_mode <> 'normal', false), incident.id, alert.id,
      alert.capture_run_id, alert.inserted_at
    FROM result_alerts alert
    JOIN result_incidents incident
      ON incident.signature = 'legacy-alert-v1:' || alert.id::text
      AND incident.workspace_id = alert.workspace_id
    LEFT JOIN capture_runs run ON run.id = alert.capture_run_id
    LEFT JOIN baseline_snapshots baseline ON baseline.id = run.baseline_snapshot_id
    """)
  end

  defp expand_notification_deliveries do
    alter table(:notification_deliveries) do
      add :result_incident_id,
          references(:result_incidents, type: :binary_id, on_delete: :delete_all)

      add :incident_occurrence_count, :integer
    end

    create index(:notification_deliveries, [:result_incident_id, :inserted_at])
    replace_notification_subject_constraint(true)
    replace_notification_identity_guard(true)
  end

  defp restore_notification_deliveries do
    replace_notification_subject_constraint(false)
    drop_if_exists index(:notification_deliveries, [:result_incident_id, :inserted_at])

    alter table(:notification_deliveries) do
      remove :incident_occurrence_count
      remove :result_incident_id
    end

    replace_notification_identity_guard(false)
  end

  defp replace_notification_subject_constraint(expanded?) do
    drop constraint(:notification_deliveries, :notification_deliveries_subject_check)

    legacy_alert = """
    kind = 'actionable_alert' AND result_alert_id IS NOT NULL AND
    monitor_id IS NULL AND deduplication_key IS NULL AND coverage_reason IS NULL AND
    coverage_retry_at IS NULL AND coverage_intended_at IS NULL
    """

    coverage = """
    kind = 'coverage_interrupted' AND result_alert_id IS NULL AND
    monitor_id IS NOT NULL AND deduplication_key IS NOT NULL AND
    coverage_reason IN ('workspace_run_limit', 'workspace_call_limit') AND
    coverage_retry_at IS NOT NULL AND coverage_intended_at IS NOT NULL
    """

    check =
      if expanded? do
        incident = """
        kind = 'actionable_alert' AND result_alert_id IS NOT NULL AND
        result_incident_id IS NOT NULL AND incident_occurrence_count > 0 AND
        monitor_id IS NULL AND deduplication_key IS NOT NULL AND coverage_reason IS NULL AND
        coverage_retry_at IS NULL AND coverage_intended_at IS NULL
        """

        "((#{legacy_alert}) AND result_incident_id IS NULL AND incident_occurrence_count IS NULL) OR (#{incident}) OR ((#{coverage}) AND result_incident_id IS NULL AND incident_occurrence_count IS NULL)"
      else
        "(#{legacy_alert}) OR (#{coverage})"
      end

    create constraint(:notification_deliveries, :notification_deliveries_subject_check,
             check: check
           )
  end

  defp replace_notification_identity_guard(expanded?) do
    incident_fields =
      if expanded?, do: "NEW.result_incident_id, NEW.incident_occurrence_count,", else: ""

    old_incident_fields =
      if expanded?, do: "OLD.result_incident_id, OLD.incident_occurrence_count,", else: ""

    execute("""
    CREATE OR REPLACE FUNCTION protect_notification_delivery_identity()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.kind, NEW.channel, NEW.workspace_id, NEW.result_alert_id, #{incident_fields}
        NEW.monitor_id, NEW.deduplication_key, NEW.coverage_reason,
        NEW.coverage_retry_at, NEW.coverage_intended_at, NEW.recipient_user_id
      ) IS DISTINCT FROM ROW(
        OLD.kind, OLD.channel, OLD.workspace_id, OLD.result_alert_id, #{old_incident_fields}
        OLD.monitor_id, OLD.deduplication_key, OLD.coverage_reason,
        OLD.coverage_retry_at, OLD.coverage_intended_at, OLD.recipient_user_id
      ) THEN
        RAISE EXCEPTION 'notification delivery identity is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
