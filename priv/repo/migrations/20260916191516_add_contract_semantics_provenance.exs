defmodule SilentRegression.Repo.Migrations.AddContractSemanticsProvenance do
  use Ecto.Migration

  def up do
    alter table(:capture_runs) do
      add :contract_semantics_fingerprint, :string, size: 64
    end

    alter table(:baseline_snapshots) do
      add :contract_semantics_fingerprint, :string, size: 64
    end

    execute("""
    UPDATE capture_runs AS run
    SET contract_semantics_fingerprint = contract.contract_fingerprint
    FROM contract_versions AS contract
    WHERE contract.id = run.contract_version_id
    """)

    execute("""
    UPDATE baseline_snapshots AS snapshot
    SET contract_semantics_fingerprint = contract.contract_fingerprint
    FROM contract_versions AS contract
    WHERE contract.id = snapshot.contract_version_id
    """)

    alter table(:capture_runs) do
      modify :contract_semantics_fingerprint, :string, size: 64, null: false
    end

    alter table(:baseline_snapshots) do
      modify :contract_semantics_fingerprint, :string, size: 64, null: false
    end

    create constraint(:capture_runs, :capture_runs_contract_semantics_fingerprint_check,
             check: "contract_semantics_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(
             :baseline_snapshots,
             :baseline_snapshots_contract_semantics_fingerprint_check,
             check: "contract_semantics_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    replace_capture_run_guard(true)
    replace_baseline_snapshot_guard(true)
  end

  def down do
    replace_capture_run_guard(false)
    replace_baseline_snapshot_guard(false)

    drop constraint(
           :baseline_snapshots,
           :baseline_snapshots_contract_semantics_fingerprint_check
         )

    drop constraint(:capture_runs, :capture_runs_contract_semantics_fingerprint_check)

    alter table(:baseline_snapshots) do
      remove :contract_semantics_fingerprint
    end

    alter table(:capture_runs) do
      remove :contract_semantics_fingerprint
    end
  end

  defp replace_capture_run_guard(include_semantics?) do
    semantics =
      if include_semantics?, do: ", NEW.contract_semantics_fingerprint", else: ""

    old_semantics =
      if include_semantics?, do: ", OLD.contract_semantics_fingerprint", else: ""

    execute("""
    CREATE OR REPLACE FUNCTION protect_capture_run_plan()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.identity_key, NEW.kind, NEW.provider, NEW.requested_model,
        NEW.monitor_fingerprint, NEW.case_set_fingerprint, NEW.contract_fingerprint#{semantics},
        NEW.evaluator_engine_version, NEW.samples_per_case, NEW.retry_limit,
        NEW.planned_call_count, NEW.maximum_call_count, NEW.workspace_id, NEW.monitor_id,
        NEW.monitor_version_id, NEW.contract_version_id, NEW.provider_credential_id,
        NEW.baseline_snapshot_id
      ) IS DISTINCT FROM ROW(
        OLD.identity_key, OLD.kind, OLD.provider, OLD.requested_model,
        OLD.monitor_fingerprint, OLD.case_set_fingerprint, OLD.contract_fingerprint#{old_semantics},
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

  defp replace_baseline_snapshot_guard(include_semantics?) do
    semantics =
      if include_semantics?, do: ", NEW.contract_semantics_fingerprint", else: ""

    old_semantics =
      if include_semantics?, do: ", OLD.contract_semantics_fingerprint", else: ""

    execute("""
    CREATE OR REPLACE FUNCTION protect_baseline_snapshot_history()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.authorization_key, NEW.preview_fingerprint, NEW.provider, NEW.requested_model,
        NEW.monitor_fingerprint, NEW.case_set_fingerprint, NEW.contract_fingerprint#{semantics},
        NEW.evaluator_engine_version, NEW.samples_per_case, NEW.retry_limit,
        NEW.planned_call_count, NEW.maximum_call_count, NEW.authorized_at,
        NEW.workspace_id, NEW.monitor_id, NEW.monitor_version_id, NEW.contract_version_id,
        NEW.provider_credential_id, NEW.capture_run_id
      ) IS DISTINCT FROM ROW(
        OLD.authorization_key, OLD.preview_fingerprint, OLD.provider, OLD.requested_model,
        OLD.monitor_fingerprint, OLD.case_set_fingerprint, OLD.contract_fingerprint#{old_semantics},
        OLD.evaluator_engine_version, OLD.samples_per_case, OLD.retry_limit,
        OLD.planned_call_count, OLD.maximum_call_count, OLD.authorized_at,
        OLD.workspace_id, OLD.monitor_id, OLD.monitor_version_id, OLD.contract_version_id,
        OLD.provider_credential_id, OLD.capture_run_id
      ) THEN
        RAISE EXCEPTION 'baseline authorization plan is immutable' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'pending' AND NEW.status NOT IN ('pending', 'approved', 'superseded', 'rejected') THEN
        RAISE EXCEPTION 'invalid baseline lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'approved' AND NEW.status NOT IN ('approved', 'superseded') THEN
        RAISE EXCEPTION 'invalid baseline lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status IN ('superseded', 'rejected') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'invalid baseline lifecycle transition' USING ERRCODE = '23514';
      END IF;

      IF OLD.status IN ('approved', 'superseded', 'rejected') AND ROW(
        NEW.approval_mode, NEW.approval_rationale, NEW.approved_at, NEW.rejected_at
      ) IS DISTINCT FROM ROW(
        OLD.approval_mode, OLD.approval_rationale, OLD.approved_at, OLD.rejected_at
      ) THEN
        RAISE EXCEPTION 'terminal baseline evidence is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
