defmodule SilentRegression.Repo.Migrations.AddProviderNativeRequestArtifacts do
  use Ecto.Migration

  def change do
    alter table(:monitor_versions) do
      add :request_mode, :string, null: false, default: "legacy_wrapped_v1"
      add :request_schema_version, :integer, null: false, default: 1
      add :request_template, :map, null: false, default: %{}
    end

    alter table(:monitor_setups) do
      add :request_mode, :string, null: false, default: "legacy_wrapped_v1"
      add :request_schema_version, :integer, null: false, default: 1
      add :request_template, :map, null: false, default: %{}
    end

    alter table(:monitor_setups) do
      modify :request_mode, :string, null: false, default: "provider_native_v1"
    end

    alter table(:provider_attempts) do
      add :request_mode, :string
      add :request_schema_version, :integer
      add :request_fingerprint, :string, size: 64
      add :request_artifact, :map
    end

    create constraint(:monitor_versions, :monitor_versions_request_mode_check,
             check: "request_mode IN ('legacy_wrapped_v1', 'provider_native_v1')"
           )

    create constraint(:monitor_versions, :monitor_versions_request_schema_check,
             check: "request_schema_version = 1"
           )

    create constraint(:monitor_setups, :monitor_setups_request_mode_check,
             check: "request_mode IN ('legacy_wrapped_v1', 'provider_native_v1')"
           )

    create constraint(:monitor_setups, :monitor_setups_request_schema_check,
             check: "request_schema_version = 1"
           )

    create constraint(:provider_attempts, :provider_attempts_request_artifact_check,
             check: """
             (request_mode IS NULL AND request_schema_version IS NULL AND
               request_fingerprint IS NULL AND request_artifact IS NULL) OR
             (request_mode IN ('legacy_wrapped_v1', 'provider_native_v1') AND
               request_schema_version = 1 AND
               request_fingerprint ~ '^[0-9a-f]{64}$' AND request_artifact IS NOT NULL)
             """
           )

    execute(update_monitor_version_guard(), restore_monitor_version_guard())
    execute(update_provider_attempt_guard(), restore_provider_attempt_guard())
  end

  defp update_monitor_version_guard do
    """
    CREATE OR REPLACE FUNCTION prevent_monitor_version_content_update()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.version, NEW.schema_version, NEW.provider, NEW.requested_model,
        NEW.system_prompt, NEW.user_prompt_template, NEW.response_format,
        NEW.generation_config, NEW.request_mode, NEW.request_schema_version,
        NEW.request_template, NEW.case_set_fingerprint, NEW.fingerprint,
        NEW.monitor_id, NEW.predecessor_id
      ) IS DISTINCT FROM ROW(
        OLD.version, OLD.schema_version, OLD.provider, OLD.requested_model,
        OLD.system_prompt, OLD.user_prompt_template, OLD.response_format,
        OLD.generation_config, OLD.request_mode, OLD.request_schema_version,
        OLD.request_template, OLD.case_set_fingerprint, OLD.fingerprint,
        OLD.monitor_id, OLD.predecessor_id
      ) THEN
        RAISE EXCEPTION 'monitor version content is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp restore_monitor_version_guard do
    """
    CREATE OR REPLACE FUNCTION prevent_monitor_version_content_update()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.version, NEW.schema_version, NEW.provider, NEW.requested_model,
        NEW.system_prompt, NEW.user_prompt_template, NEW.response_format,
        NEW.generation_config, NEW.case_set_fingerprint, NEW.fingerprint,
        NEW.monitor_id, NEW.predecessor_id
      ) IS DISTINCT FROM ROW(
        OLD.version, OLD.schema_version, OLD.provider, OLD.requested_model,
        OLD.system_prompt, OLD.user_prompt_template, OLD.response_format,
        OLD.generation_config, OLD.case_set_fingerprint, OLD.fingerprint,
        OLD.monitor_id, OLD.predecessor_id
      ) THEN
        RAISE EXCEPTION 'monitor version content is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp update_provider_attempt_guard do
    """
    CREATE OR REPLACE FUNCTION protect_provider_attempt_evidence()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(NEW.capture_run_id, NEW.capture_observation_id, NEW.attempt_number,
             NEW.client_request_id, NEW.started_at, NEW.request_mode,
             NEW.request_schema_version, NEW.request_fingerprint, NEW.request_artifact)
         IS DISTINCT FROM
         ROW(OLD.capture_run_id, OLD.capture_observation_id, OLD.attempt_number,
             OLD.client_request_id, OLD.started_at, OLD.request_mode,
             OLD.request_schema_version, OLD.request_fingerprint, OLD.request_artifact) THEN
        RAISE EXCEPTION 'provider attempt identity is immutable' USING ERRCODE = '23514';
      END IF;

      IF OLD.status <> 'started' THEN
        RAISE EXCEPTION 'terminal provider attempt is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp restore_provider_attempt_guard do
    """
    CREATE OR REPLACE FUNCTION protect_provider_attempt_evidence()
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
    """
  end
end
