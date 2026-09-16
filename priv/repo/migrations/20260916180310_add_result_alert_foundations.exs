defmodule SilentRegression.Repo.Migrations.AddResultAlertFoundations do
  use Ecto.Migration

  def up do
    alter table(:capture_runs) do
      add :baseline_snapshot_id,
          references(:baseline_snapshots, type: :binary_id, on_delete: :restrict)
    end

    create index(:capture_runs, [:baseline_snapshot_id])

    execute("""
    UPDATE capture_runs AS run
    SET baseline_snapshot_id = (
      SELECT snapshot.id
      FROM baseline_snapshots AS snapshot
      WHERE snapshot.workspace_id = run.workspace_id
        AND snapshot.monitor_id = run.monitor_id
        AND snapshot.monitor_version_id = run.monitor_version_id
        AND snapshot.contract_version_id = run.contract_version_id
        AND snapshot.provider_credential_id = run.provider_credential_id
        AND snapshot.provider = run.provider
        AND snapshot.requested_model = run.requested_model
        AND snapshot.monitor_fingerprint = run.monitor_fingerprint
        AND snapshot.case_set_fingerprint = run.case_set_fingerprint
        AND snapshot.contract_fingerprint = run.contract_fingerprint
        AND snapshot.evaluator_engine_version = run.evaluator_engine_version
        AND snapshot.status IN ('approved', 'superseded')
        AND snapshot.approved_at <= COALESCE(run.started_at, run.inserted_at)
      ORDER BY snapshot.approved_at DESC, snapshot.id DESC
      LIMIT 1
    )
    WHERE run.kind IN ('manual', 'scheduled')
      AND run.baseline_snapshot_id IS NULL
    """)

    alter table(:capture_rule_results) do
      add :severity, :string, null: false, default: "critical"
    end

    create constraint(:capture_rule_results, :capture_rule_results_severity_check,
             check: "severity IN ('critical', 'warning')"
           )

    execute("""
    CREATE OR REPLACE FUNCTION protect_capture_run_plan()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.identity_key, NEW.kind, NEW.provider, NEW.requested_model,
        NEW.monitor_fingerprint, NEW.case_set_fingerprint, NEW.contract_fingerprint,
        NEW.evaluator_engine_version, NEW.samples_per_case, NEW.retry_limit,
        NEW.planned_call_count, NEW.maximum_call_count, NEW.workspace_id, NEW.monitor_id,
        NEW.monitor_version_id, NEW.contract_version_id, NEW.provider_credential_id,
        NEW.baseline_snapshot_id
      ) IS DISTINCT FROM ROW(
        OLD.identity_key, OLD.kind, OLD.provider, OLD.requested_model,
        OLD.monitor_fingerprint, OLD.case_set_fingerprint, OLD.contract_fingerprint,
        OLD.evaluator_engine_version, OLD.samples_per_case, OLD.retry_limit,
        OLD.planned_call_count, OLD.maximum_call_count, OLD.workspace_id, OLD.monitor_id,
        OLD.monitor_version_id, OLD.contract_version_id, OLD.provider_credential_id,
        OLD.baseline_snapshot_id
      ) THEN
        RAISE EXCEPTION 'capture run plan is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION protect_capture_run_plan()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.identity_key, NEW.kind, NEW.provider, NEW.requested_model,
        NEW.monitor_fingerprint, NEW.case_set_fingerprint, NEW.contract_fingerprint,
        NEW.evaluator_engine_version, NEW.samples_per_case, NEW.retry_limit,
        NEW.planned_call_count, NEW.maximum_call_count, NEW.workspace_id, NEW.monitor_id,
        NEW.monitor_version_id, NEW.contract_version_id, NEW.provider_credential_id
      ) IS DISTINCT FROM ROW(
        OLD.identity_key, OLD.kind, OLD.provider, OLD.requested_model,
        OLD.monitor_fingerprint, OLD.case_set_fingerprint, OLD.contract_fingerprint,
        OLD.evaluator_engine_version, OLD.samples_per_case, OLD.retry_limit,
        OLD.planned_call_count, OLD.maximum_call_count, OLD.workspace_id, OLD.monitor_id,
        OLD.monitor_version_id, OLD.contract_version_id, OLD.provider_credential_id
      ) THEN
        RAISE EXCEPTION 'capture run plan is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    drop constraint(:capture_rule_results, :capture_rule_results_severity_check)

    alter table(:capture_rule_results) do
      remove :severity
    end

    drop index(:capture_runs, [:baseline_snapshot_id])

    alter table(:capture_runs) do
      remove :baseline_snapshot_id
    end
  end
end
