defmodule SilentRegression.Repo.Migrations.CreateCaptureExecutionRecords do
  use Ecto.Migration

  def change do
    create table(:capture_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identity_key, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "planned"
      add :provider, :string, null: false
      add :requested_model, :string, null: false
      add :monitor_fingerprint, :string, size: 64, null: false
      add :case_set_fingerprint, :string, size: 64, null: false
      add :contract_fingerprint, :string, size: 64, null: false
      add :evaluator_engine_version, :string, null: false
      add :samples_per_case, :integer, null: false
      add :retry_limit, :integer, null: false
      add :planned_call_count, :integer, null: false
      add :maximum_call_count, :integer, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :cancellation_requested_at, :utc_datetime_usec

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_version_id,
          references(:monitor_versions, type: :binary_id),
          null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id),
          null: false

      add :provider_credential_id,
          references(:provider_credentials, type: :binary_id),
          null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:capture_runs, [:workspace_id, :identity_key])
    create index(:capture_runs, [:workspace_id, :monitor_id, :inserted_at])
    create index(:capture_runs, [:monitor_id, :status])
    create index(:capture_runs, [:monitor_version_id])
    create index(:capture_runs, [:contract_version_id])

    create constraint(:capture_runs, :capture_runs_kind_check,
             check: "kind IN ('baseline', 'manual', 'scheduled')"
           )

    create constraint(:capture_runs, :capture_runs_status_check,
             check:
               "status IN ('planned', 'queued', 'running', 'succeeded', 'partial_failed', 'failed', 'cancelled', 'needs_review')"
           )

    create constraint(:capture_runs, :capture_runs_provider_check,
             check: "provider IN ('openai', 'anthropic')"
           )

    create constraint(:capture_runs, :capture_runs_counts_check,
             check: """
             samples_per_case > 0 AND
             retry_limit >= 0 AND retry_limit <= 5 AND
             planned_call_count > 0 AND
             maximum_call_count >= planned_call_count AND
             maximum_call_count <= planned_call_count * (retry_limit + 1)
             """
           )

    create constraint(:capture_runs, :capture_runs_fingerprints_check,
             check: """
             monitor_fingerprint ~ '^[0-9a-f]{64}$' AND
             case_set_fingerprint ~ '^[0-9a-f]{64}$' AND
             contract_fingerprint ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:capture_runs, :capture_runs_lifecycle_check,
             check: """
             (status IN ('planned', 'queued') AND started_at IS NULL AND completed_at IS NULL) OR
             (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL) OR
             (status IN ('succeeded', 'partial_failed', 'failed', 'needs_review') AND started_at IS NOT NULL AND completed_at IS NOT NULL) OR
             (status = 'cancelled' AND completed_at IS NOT NULL)
             """
           )

    create table(:capture_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sample_index, :integer, null: false
      add :status, :string, null: false, default: "planned"
      add :case_fingerprint, :string, size: 64, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :requested_model, :string
      add :returned_model, :string
      add :output_text, :text
      add :completion_state, :string
      add :finish_reason, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :latency_ms, :integer
      add :provider_request_id, :string
      add :failure_category, :string
      add :failure_message, :string
      add :provider_metadata, :map, null: false, default: %{}
      add :captured_at, :utc_datetime_usec
      add :terminal_at, :utc_datetime_usec

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :case_version_id,
          references(:case_versions, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :capture_observations,
             [
               :capture_run_id,
               :case_version_id,
               :sample_index
             ], name: :capture_observations_run_case_sample_index)

    create index(:capture_observations, [:capture_run_id, :status])
    create index(:capture_observations, [:case_version_id])
    create index(:capture_observations, [:provider_request_id])

    create constraint(:capture_observations, :capture_observations_sample_index_check,
             check: "sample_index >= 0"
           )

    create constraint(:capture_observations, :capture_observations_status_check,
             check:
               "status IN ('planned', 'running', 'retrying', 'succeeded', 'failed', 'unknown', 'cancelled')"
           )

    create constraint(:capture_observations, :capture_observations_completion_state_check,
             check:
               "completion_state IS NULL OR completion_state IN ('complete', 'incomplete', 'unknown')"
           )

    create constraint(:capture_observations, :capture_observations_failure_category_check,
             check: """
             failure_category IS NULL OR failure_category IN (
               'authentication', 'authorization', 'rate_limited', 'invalid_request',
               'request_too_large', 'timeout', 'transport', 'provider_unavailable',
               'malformed_response', 'model_mismatch', 'call_cap_exceeded',
               'credential_unavailable', 'unknown_outcome'
             )
             """
           )

    create constraint(:capture_observations, :capture_observations_usage_check,
             check: """
             (input_tokens IS NULL OR input_tokens >= 0) AND
             (output_tokens IS NULL OR output_tokens >= 0) AND
             (latency_ms IS NULL OR latency_ms >= 0)
             """
           )

    create constraint(:capture_observations, :capture_observations_fingerprints_check,
             check:
               "case_fingerprint ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:capture_observations, :capture_observations_lifecycle_check,
             check: """
             (status IN ('planned', 'running', 'retrying') AND terminal_at IS NULL) OR
             (status = 'succeeded' AND terminal_at IS NOT NULL AND captured_at IS NOT NULL AND
               requested_model IS NOT NULL AND returned_model IS NOT NULL AND output_text IS NOT NULL AND
               completion_state IS NOT NULL AND input_tokens IS NOT NULL AND output_tokens IS NOT NULL AND
               latency_ms IS NOT NULL AND failure_category IS NULL AND failure_message IS NULL) OR
             (status = 'failed' AND terminal_at IS NOT NULL AND failure_category IS NOT NULL AND
               failure_message IS NOT NULL) OR
             (status = 'unknown' AND terminal_at IS NOT NULL AND failure_category = 'unknown_outcome' AND
               failure_message IS NOT NULL AND completion_state = 'unknown') OR
             (status = 'cancelled' AND terminal_at IS NOT NULL)
             """
           )

    create table(:provider_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :attempt_number, :integer, null: false
      add :status, :string, null: false, default: "started"
      add :client_request_id, :string, null: false
      add :provider_request_id, :string
      add :retryable, :boolean
      add :failure_category, :string
      add :failure_message, :string
      add :latency_ms, :integer
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_observation_id,
          references(:capture_observations, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_attempts, [:capture_observation_id, :attempt_number])
    create unique_index(:provider_attempts, [:client_request_id])
    create index(:provider_attempts, [:capture_run_id, :inserted_at])
    create index(:provider_attempts, [:provider_request_id])

    create constraint(:provider_attempts, :provider_attempts_attempt_number_check,
             check: "attempt_number > 0"
           )

    create constraint(:provider_attempts, :provider_attempts_status_check,
             check: "status IN ('started', 'succeeded', 'failed', 'unknown')"
           )

    create constraint(:provider_attempts, :provider_attempts_failure_category_check,
             check: """
             failure_category IS NULL OR failure_category IN (
               'authentication', 'authorization', 'rate_limited', 'invalid_request',
               'request_too_large', 'timeout', 'transport', 'provider_unavailable',
               'malformed_response', 'model_mismatch', 'call_cap_exceeded',
               'credential_unavailable', 'unknown_outcome'
             )
             """
           )

    create constraint(:provider_attempts, :provider_attempts_latency_check,
             check: "latency_ms IS NULL OR latency_ms >= 0"
           )

    create constraint(:provider_attempts, :provider_attempts_lifecycle_check,
             check: """
             (status = 'started' AND finished_at IS NULL AND retryable IS NULL AND
               failure_category IS NULL AND failure_message IS NULL) OR
             (status = 'succeeded' AND finished_at IS NOT NULL AND retryable = FALSE AND
               failure_category IS NULL AND failure_message IS NULL AND latency_ms IS NOT NULL) OR
             (status = 'failed' AND finished_at IS NOT NULL AND retryable IS NOT NULL AND
               failure_category IS NOT NULL AND failure_message IS NOT NULL AND latency_ms IS NOT NULL) OR
             (status = 'unknown' AND finished_at IS NOT NULL AND retryable = FALSE AND
               failure_category = 'unknown_outcome' AND failure_message IS NOT NULL)
             """
           )

    create table(:capture_evaluations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :evaluator_engine_version, :string, null: false
      add :contract_fingerprint, :string, size: 64, null: false
      add :status, :string, null: false
      add :root_rule_id, :string, null: false
      add :error, :map
      add :evaluated_at, :utc_datetime_usec, null: false

      add :capture_observation_id,
          references(:capture_observations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :capture_evaluations,
             [
               :capture_observation_id,
               :contract_version_id,
               :evaluator_engine_version
             ], name: :capture_evaluations_observation_contract_engine_index)

    create index(:capture_evaluations, [:contract_version_id])
    create index(:capture_evaluations, [:status])

    create constraint(:capture_evaluations, :capture_evaluations_status_check,
             check: "status IN ('pass', 'fail', 'evaluator_error')"
           )

    create constraint(:capture_evaluations, :capture_evaluations_fingerprint_check,
             check: "contract_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:capture_evaluations, :capture_evaluations_error_check,
             check:
               "(status = 'evaluator_error' AND error IS NOT NULL) OR (status IN ('pass', 'fail'))"
           )

    create table(:capture_rule_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position, :integer, null: false
      add :rule_id, :string, null: false
      add :rule_type, :string, null: false
      add :status, :string, null: false
      add :code, :string, null: false
      add :explanation, :string, null: false
      add :evidence, :map, null: false, default: %{}
      add :child_rule_ids, {:array, :string}, null: false, default: []

      add :capture_evaluation_id,
          references(:capture_evaluations, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:capture_rule_results, [:capture_evaluation_id, :rule_id])
    create unique_index(:capture_rule_results, [:capture_evaluation_id, :position])

    create constraint(:capture_rule_results, :capture_rule_results_position_check,
             check: "position >= 0"
           )

    create constraint(:capture_rule_results, :capture_rule_results_status_check,
             check: "status IN ('pass', 'fail', 'evaluator_error')"
           )

    execute(
      """
      CREATE FUNCTION protect_capture_run_plan()
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
      """,
      "DROP FUNCTION IF EXISTS protect_capture_run_plan()"
    )

    execute(
      """
      CREATE TRIGGER capture_runs_plan_guard
      BEFORE UPDATE ON capture_runs
      FOR EACH ROW EXECUTE FUNCTION protect_capture_run_plan();
      """,
      "DROP TRIGGER IF EXISTS capture_runs_plan_guard ON capture_runs"
    )

    execute(
      """
      CREATE FUNCTION protect_capture_observation_evidence()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(NEW.capture_run_id, NEW.case_version_id, NEW.sample_index,
               NEW.case_fingerprint, NEW.request_fingerprint)
           IS DISTINCT FROM
           ROW(OLD.capture_run_id, OLD.case_version_id, OLD.sample_index,
               OLD.case_fingerprint, OLD.request_fingerprint) THEN
          RAISE EXCEPTION 'capture observation identity is immutable' USING ERRCODE = '23514';
        END IF;

        IF OLD.status IN ('succeeded', 'failed', 'unknown', 'cancelled') THEN
          RAISE EXCEPTION 'terminal capture observation is immutable' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS protect_capture_observation_evidence()"
    )

    execute(
      """
      CREATE TRIGGER capture_observations_evidence_guard
      BEFORE UPDATE ON capture_observations
      FOR EACH ROW EXECUTE FUNCTION protect_capture_observation_evidence();
      """,
      "DROP TRIGGER IF EXISTS capture_observations_evidence_guard ON capture_observations"
    )

    execute(
      """
      CREATE FUNCTION protect_provider_attempt_evidence()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(NEW.capture_run_id, NEW.capture_observation_id, NEW.attempt_number,
               NEW.client_request_id, NEW.started_at)
           IS DISTINCT FROM
           ROW(OLD.capture_run_id, OLD.capture_observation_id, OLD.attempt_number,
               OLD.client_request_id, OLD.started_at) THEN
          RAISE EXCEPTION 'provider attempt identity is immutable' USING ERRCODE = '23514';
        END IF;

        IF OLD.status <> 'started' THEN
          RAISE EXCEPTION 'terminal provider attempt is immutable' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS protect_provider_attempt_evidence()"
    )

    execute(
      """
      CREATE TRIGGER provider_attempts_evidence_guard
      BEFORE UPDATE ON provider_attempts
      FOR EACH ROW EXECUTE FUNCTION protect_provider_attempt_evidence();
      """,
      "DROP TRIGGER IF EXISTS provider_attempts_evidence_guard ON provider_attempts"
    )

    execute(
      """
      CREATE FUNCTION reject_capture_evidence_update()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'capture evaluation evidence is immutable' USING ERRCODE = '23514';
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS reject_capture_evidence_update()"
    )

    execute(
      """
      CREATE TRIGGER capture_evaluations_update_guard
      BEFORE UPDATE ON capture_evaluations
      FOR EACH ROW EXECUTE FUNCTION reject_capture_evidence_update();
      """,
      "DROP TRIGGER IF EXISTS capture_evaluations_update_guard ON capture_evaluations"
    )

    execute(
      """
      CREATE TRIGGER capture_rule_results_update_guard
      BEFORE UPDATE ON capture_rule_results
      FOR EACH ROW EXECUTE FUNCTION reject_capture_evidence_update();
      """,
      "DROP TRIGGER IF EXISTS capture_rule_results_update_guard ON capture_rule_results"
    )
  end
end
