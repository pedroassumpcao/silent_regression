defmodule SilentRegression.Repo.Migrations.AddWorkspaceRetentionAndPurgeControls do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :closed_at, :utc_datetime
      add :deletion_requested_at, :utc_datetime
      add :purge_after, :utc_datetime
      add :closed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workspaces, [:purge_after], where: "status = 'closed'")

    create constraint(:workspaces, :workspaces_retention_lifecycle_check,
             check: """
             (status <> 'closed' AND closed_at IS NULL AND deletion_requested_at IS NULL AND
               purge_after IS NULL AND closed_by_user_id IS NULL) OR
             (status = 'closed' AND closed_at IS NOT NULL AND purge_after IS NOT NULL AND
               purge_after >= closed_at AND
               (deletion_requested_at IS NULL OR deletion_requested_at >= closed_at))
             """
           )

    create table(:workspace_deletion_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_id, :binary_id, null: false
      add :workspace_fingerprint, :binary, null: false
      add :request_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :requested_at, :utc_datetime, null: false
      add :purge_due_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :cancelled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_deletion_receipts, [:request_id])
    create index(:workspace_deletion_receipts, [:workspace_fingerprint, :status])
    create index(:workspace_deletion_receipts, [:status, :purge_due_at])

    create constraint(:workspace_deletion_receipts, :workspace_deletion_receipts_type_check,
             check: "request_type IN ('closure_retention', 'explicit_request')"
           )

    create constraint(:workspace_deletion_receipts, :workspace_deletion_receipts_status_check,
             check: "status IN ('pending', 'cancelled', 'completed')"
           )

    create constraint(
             :workspace_deletion_receipts,
             :workspace_deletion_receipts_fingerprint_check,
             check: "octet_length(workspace_fingerprint) = 32"
           )

    create constraint(:workspace_deletion_receipts, :workspace_deletion_receipts_lifecycle_check,
             check: """
             (status = 'pending' AND completed_at IS NULL AND cancelled_at IS NULL) OR
             (status = 'completed' AND completed_at IS NOT NULL AND cancelled_at IS NULL) OR
             (status = 'cancelled' AND completed_at IS NULL AND cancelled_at IS NOT NULL)
             """
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

    install_purge_aware_guards()
  end

  def down do
    restore_guards()

    drop constraint(:monitors, :monitors_pause_reason_check)

    create constraint(:monitors, :monitors_pause_reason_check,
             check:
               "pause_reason IS NULL OR pause_reason IN ('owner_paused', 'credential_unavailable', 'incompatible_configuration', 'repeated_authentication_failures', 'workspace_call_limit', 'schedule_owner_unavailable')"
           )

    drop table(:workspace_deletion_receipts)
    drop constraint(:workspaces, :workspaces_retention_lifecycle_check)

    alter table(:workspaces) do
      remove :closed_by_user_id
      remove :purge_after
      remove :deletion_requested_at
      remove :closed_at
    end
  end

  defp install_purge_aware_guards do
    execute(purge_aware_capture_run_guard())
    execute(purge_aware_result_alert_guard())
    execute(purge_aware_contract_fixture_guard())

    execute(
      purge_aware_append_only_guard(
        "protect_review_decision_history",
        "review decisions are append-only"
      )
    )

    execute(
      purge_aware_append_only_guard(
        "protect_contract_rescore_summary",
        "contract rescore summaries are immutable"
      )
    )

    execute(purge_aware_review_origin_guard())
  end

  defp restore_guards do
    execute(String.replace(purge_aware_capture_run_guard(), purge_bypass(), ""))
    execute(String.replace(purge_aware_result_alert_guard(), purge_bypass(), ""))
    execute(String.replace(purge_aware_contract_fixture_guard(), purge_bypass(), ""))

    execute("""
    CREATE OR REPLACE FUNCTION protect_review_decision_history()
    RETURNS trigger AS $$ BEGIN
      RAISE EXCEPTION 'review decisions are append-only' USING ERRCODE = '23514';
    END; $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION protect_contract_rescore_summary()
    RETURNS trigger AS $$ BEGIN
      RAISE EXCEPTION 'contract rescore summaries are immutable' USING ERRCODE = '23514';
    END; $$ LANGUAGE plpgsql;
    """)

    execute(String.replace(purge_aware_review_origin_guard(), purge_bypass(), ""))
  end

  defp purge_aware_append_only_guard(function_name, message) do
    """
    CREATE OR REPLACE FUNCTION #{function_name}()
    RETURNS trigger AS $$
    BEGIN
      #{purge_bypass()}
      RAISE EXCEPTION '#{message}' USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp purge_aware_contract_fixture_guard do
    """
    CREATE OR REPLACE FUNCTION protect_contract_fixture_history()
    RETURNS trigger AS $$
    DECLARE parent_id uuid; parent_status text;
    BEGIN
      #{purge_bypass()}
      IF TG_OP = 'DELETE' THEN parent_id := OLD.contract_version_id;
      ELSE parent_id := NEW.contract_version_id;
      END IF;
      SELECT status INTO parent_status FROM contract_versions WHERE id = parent_id;
      IF parent_status IS NOT NULL AND parent_status <> 'draft' THEN
        RAISE EXCEPTION 'approved contract fixtures are immutable' USING ERRCODE = '23514';
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp purge_aware_review_origin_guard do
    """
    CREATE OR REPLACE FUNCTION protect_review_contract_revision_origin()
    RETURNS trigger AS $$
    BEGIN
      #{purge_bypass()}
      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (
          SELECT 1 FROM review_decisions AS decision
          JOIN contract_versions AS contract ON contract.id = NEW.contract_version_id
          WHERE decision.id = NEW.review_decision_id
            AND decision.workspace_id = contract.workspace_id
            AND decision.monitor_id = contract.monitor_id
        ) THEN
          RAISE EXCEPTION 'review and contract revision provenance must match' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'review contract revision origins are immutable' USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp purge_aware_capture_run_guard do
    """
    CREATE OR REPLACE FUNCTION protect_capture_run_plan()
    RETURNS trigger AS $$
    BEGIN
      #{purge_bypass()}
      IF ROW(
        NEW.identity_key, NEW.kind, NEW.provider, NEW.requested_model,
        NEW.monitor_fingerprint, NEW.case_set_fingerprint, NEW.contract_fingerprint,
        NEW.contract_semantics_fingerprint, NEW.evaluator_engine_version, NEW.samples_per_case,
        NEW.retry_limit, NEW.planned_call_count, NEW.maximum_call_count, NEW.workspace_id,
        NEW.monitor_id, NEW.monitor_version_id, NEW.contract_version_id,
        NEW.provider_credential_id, NEW.baseline_snapshot_id
      ) IS DISTINCT FROM ROW(
        OLD.identity_key, OLD.kind, OLD.provider, OLD.requested_model,
        OLD.monitor_fingerprint, OLD.case_set_fingerprint, OLD.contract_fingerprint,
        OLD.contract_semantics_fingerprint, OLD.evaluator_engine_version, OLD.samples_per_case,
        OLD.retry_limit, OLD.planned_call_count, OLD.maximum_call_count, OLD.workspace_id,
        OLD.monitor_id, OLD.monitor_version_id, OLD.contract_version_id,
        OLD.provider_credential_id, OLD.baseline_snapshot_id
      ) THEN
        RAISE EXCEPTION 'capture run plan is immutable' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp purge_aware_result_alert_guard do
    """
    CREATE OR REPLACE FUNCTION protect_result_alert()
    RETURNS trigger AS $$
    BEGIN
      #{purge_bypass()}
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
      IF OLD.status <> 'resolved' AND NEW.status = 'resolved' AND
         NEW.resolution_review_decision_id IS NULL THEN
        RAISE EXCEPTION 'review decision is required for resolution' USING ERRCODE = '23514';
      END IF;
      IF OLD.status <> 'resolved' AND NEW.status = 'resolved' AND NOT EXISTS (
        SELECT 1 FROM review_decisions AS decision
        WHERE decision.id = NEW.resolution_review_decision_id
          AND decision.workspace_id = NEW.workspace_id
          AND decision.result_alert_id = NEW.id
      ) THEN
        RAISE EXCEPTION 'resolution review decision does not belong to alert' USING ERRCODE = '23514';
      END IF;
      IF OLD.status = 'resolved' AND
         NEW.resolution_review_decision_id IS DISTINCT FROM OLD.resolution_review_decision_id THEN
        RAISE EXCEPTION 'alert resolution decision is immutable' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp purge_bypass do
    """
    IF current_setting('silent_regression.customer_purge', true) = 'on' THEN
      IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;
    """
  end
end
