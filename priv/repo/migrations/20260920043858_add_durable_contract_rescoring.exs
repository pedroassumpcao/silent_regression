defmodule SilentRegression.Repo.Migrations.AddDurableContractRescoring do
  use Ecto.Migration

  def up do
    drop constraint(:contract_versions, :contract_versions_status_check)
    drop constraint(:contract_versions, :contract_versions_lifecycle_check)

    create constraint(:contract_versions, :contract_versions_status_check,
             check:
               "status IN ('draft', 'pending_rescore', 'rescore_failed', 'approved', 'retired')"
           )

    create constraint(:contract_versions, :contract_versions_lifecycle_check,
             check: """
             (status IN ('draft', 'pending_rescore', 'rescore_failed') AND
               approved_at IS NULL AND retired_at IS NULL) OR
             (status = 'approved' AND approved_at IS NOT NULL AND retired_at IS NULL) OR
             (status = 'retired' AND approved_at IS NOT NULL AND retired_at IS NOT NULL)
             """
           )

    create unique_index(:contract_versions, [:monitor_id],
             where: "status IN ('draft', 'pending_rescore')",
             name: :contract_versions_one_active_candidate_index
           )

    create table(:contract_rescore_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "pending"
      add :batch_size, :integer, null: false
      add :total_count, :integer, null: false
      add :processed_count, :integer, null: false, default: 0
      add :pass_count, :integer, null: false, default: 0
      add :fail_count, :integer, null: false, default: 0
      add :evaluator_error_count, :integer, null: false, default: 0
      add :error, :map
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      add :contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :predecessor_contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :nilify_all)

      add :requested_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:contract_rescore_runs, [:contract_version_id])
    create index(:contract_rescore_runs, [:status, :inserted_at])
    create index(:contract_rescore_runs, [:predecessor_contract_version_id])

    create constraint(:contract_rescore_runs, :contract_rescore_runs_status_check,
             check: "status IN ('pending', 'running', 'succeeded', 'failed')"
           )

    create constraint(:contract_rescore_runs, :contract_rescore_runs_counts_check,
             check: """
             batch_size BETWEEN 1 AND 500 AND total_count > 0 AND processed_count >= 0 AND
             pass_count >= 0 AND fail_count >= 0 AND evaluator_error_count >= 0 AND
             processed_count = pass_count + fail_count + evaluator_error_count AND
             processed_count <= total_count
             """
           )

    create constraint(:contract_rescore_runs, :contract_rescore_runs_lifecycle_check,
             check: """
             (status = 'pending' AND started_at IS NULL AND completed_at IS NULL AND error IS NULL) OR
             (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL AND error IS NULL) OR
             (status = 'succeeded' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND
               processed_count = total_count AND evaluator_error_count = 0 AND error IS NULL) OR
             (status = 'failed' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND
               error IS NOT NULL)
             """
           )

    create table(:contract_rescore_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :error, :map
      add :processed_at, :utc_datetime_usec

      add :contract_rescore_run_id,
          references(:contract_rescore_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_observation_id,
          references(:capture_observations, type: :binary_id, on_delete: :restrict),
          null: false

      add :capture_evaluation_id,
          references(:capture_evaluations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:contract_rescore_items, [
             :contract_rescore_run_id,
             :capture_observation_id
           ])

    create unique_index(:contract_rescore_items, [:contract_rescore_run_id, :position])
    create index(:contract_rescore_items, [:contract_rescore_run_id, :status, :position])
    create index(:contract_rescore_items, [:capture_observation_id])

    create constraint(:contract_rescore_items, :contract_rescore_items_position_check,
             check: "position >= 0"
           )

    create constraint(:contract_rescore_items, :contract_rescore_items_status_check,
             check: "status IN ('pending', 'pass', 'fail', 'evaluator_error')"
           )

    create constraint(:contract_rescore_items, :contract_rescore_items_lifecycle_check,
             check: """
             (status = 'pending' AND capture_evaluation_id IS NULL AND processed_at IS NULL AND error IS NULL) OR
             (status IN ('pass', 'fail') AND capture_evaluation_id IS NOT NULL AND
               processed_at IS NOT NULL AND error IS NULL) OR
             (status = 'evaluator_error' AND processed_at IS NOT NULL AND error IS NOT NULL)
             """
           )

    execute(contract_version_guard())
  end

  def down do
    drop table(:contract_rescore_items)
    drop table(:contract_rescore_runs)

    drop index(:contract_versions, [:monitor_id],
           name: :contract_versions_one_active_candidate_index
         )

    drop constraint(:contract_versions, :contract_versions_status_check)
    drop constraint(:contract_versions, :contract_versions_lifecycle_check)

    create constraint(:contract_versions, :contract_versions_status_check,
             check: "status IN ('draft', 'approved', 'retired')"
           )

    create constraint(:contract_versions, :contract_versions_lifecycle_check,
             check: """
             (status = 'draft' AND approved_at IS NULL AND retired_at IS NULL) OR
             (status = 'approved' AND approved_at IS NOT NULL AND retired_at IS NULL) OR
             (status = 'retired' AND approved_at IS NOT NULL AND retired_at IS NOT NULL)
             """
           )

    execute(legacy_contract_version_guard())
  end

  defp contract_version_guard do
    """
    CREATE OR REPLACE FUNCTION protect_contract_version_history()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'draft' AND ROW(
        NEW.version, NEW.schema_version, NEW.evaluator_engine_version, NEW.template_key,
        NEW.template_usage, NEW.assistance_mode, NEW.root, NEW.contract_fingerprint,
        NEW.fixture_set_fingerprint, NEW.fingerprint, NEW.proof_schema_version,
        NEW.proof_fingerprint, NEW.workspace_id, NEW.monitor_id, NEW.monitor_version_id,
        NEW.predecessor_id
      ) IS DISTINCT FROM ROW(
        OLD.version, OLD.schema_version, OLD.evaluator_engine_version, OLD.template_key,
        OLD.template_usage, OLD.assistance_mode, OLD.root, OLD.contract_fingerprint,
        OLD.fixture_set_fingerprint, OLD.fingerprint, OLD.proof_schema_version,
        OLD.proof_fingerprint, OLD.workspace_id, OLD.monitor_id, OLD.monitor_version_id,
        OLD.predecessor_id
      ) THEN
        RAISE EXCEPTION 'approved contract version content is immutable' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'draft' AND NEW.status NOT IN ('draft', 'approved', 'pending_rescore') THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'pending_rescore' AND NEW.status NOT IN ('pending_rescore', 'approved', 'rescore_failed') THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'rescore_failed' AND NEW.status <> 'rescore_failed' THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'approved' AND NEW.status NOT IN ('approved', 'retired') THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp legacy_contract_version_guard do
    """
    CREATE OR REPLACE FUNCTION protect_contract_version_history()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.status <> 'draft' AND ROW(
        NEW.version, NEW.schema_version, NEW.evaluator_engine_version, NEW.template_key,
        NEW.template_usage, NEW.assistance_mode, NEW.root, NEW.contract_fingerprint,
        NEW.fixture_set_fingerprint, NEW.fingerprint, NEW.proof_schema_version,
        NEW.proof_fingerprint, NEW.workspace_id, NEW.monitor_id, NEW.monitor_version_id,
        NEW.predecessor_id
      ) IS DISTINCT FROM ROW(
        OLD.version, OLD.schema_version, OLD.evaluator_engine_version, OLD.template_key,
        OLD.template_usage, OLD.assistance_mode, OLD.root, OLD.contract_fingerprint,
        OLD.fixture_set_fingerprint, OLD.fingerprint, OLD.proof_schema_version,
        OLD.proof_fingerprint, OLD.workspace_id, OLD.monitor_id, OLD.monitor_version_id,
        OLD.predecessor_id
      ) THEN
        RAISE EXCEPTION 'approved contract version content is immutable' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'draft' AND NEW.status NOT IN ('draft', 'approved') THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'approved' AND NEW.status NOT IN ('approved', 'retired') THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'retired' AND NEW.status <> 'retired' THEN
        RAISE EXCEPTION 'invalid contract lifecycle transition' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
