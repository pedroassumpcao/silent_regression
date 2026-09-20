defmodule SilentRegression.Repo.Migrations.AddCaseSpecificExpectations do
  use Ecto.Migration

  @none_fingerprint "15eacbbb4c6113c8cf5a19afec474a07fd240d9e84dff30b87dc126f15004c77"

  def up do
    alter table(:case_versions) do
      add :expectation_schema_version, :string,
        null: false,
        default: "no_case_expectation"

      add :expectation, :map, null: false, default: %{}
      add :expectation_fingerprint, :string, size: 64, null: false, default: @none_fingerprint
    end

    create constraint(:case_versions, :case_versions_expectation_check,
             check: """
             expectation_schema_version IN ('no_case_expectation', 'case_expectation_v1') AND
             expectation_fingerprint ~ '^[0-9a-f]{64}$' AND
             (expectation_schema_version <> 'no_case_expectation' OR expectation = '{}'::jsonb)
             """
           )

    execute(update_case_version_guard())

    alter table(:capture_evaluations) do
      add :contract_status, :string

      add :case_expectation_schema_version, :string,
        null: false,
        default: "no_case_expectation"

      add :case_expectation_fingerprint, :string,
        size: 64,
        null: false,
        default: @none_fingerprint

      add :case_expectation_status, :string, null: false, default: "not_configured"
      add :case_expectation_results, :map, null: false, default: %{"checks" => []}
      add :case_expectation_error, :map
    end

    execute("DROP TRIGGER IF EXISTS capture_evaluations_update_guard ON capture_evaluations")
    execute("UPDATE capture_evaluations SET contract_status = status")

    execute("""
    CREATE TRIGGER capture_evaluations_update_guard
    BEFORE UPDATE ON capture_evaluations
    FOR EACH ROW EXECUTE FUNCTION reject_capture_evidence_update();
    """)

    alter table(:capture_evaluations) do
      modify :contract_status, :string, null: false
    end

    create constraint(:capture_evaluations, :capture_evaluations_contract_status_check,
             check: "contract_status IN ('pass', 'fail', 'evaluator_error')"
           )

    create constraint(:capture_evaluations, :capture_evaluations_expectation_check,
             check: """
             case_expectation_schema_version IN
               ('no_case_expectation', 'case_expectation_v1') AND
             case_expectation_fingerprint ~ '^[0-9a-f]{64}$' AND
             case_expectation_status IN
               ('not_configured', 'pass', 'fail', 'evaluator_error') AND
             ((case_expectation_status = 'evaluator_error' AND
                 case_expectation_error IS NOT NULL) OR
               (case_expectation_status IN ('not_configured', 'pass', 'fail') AND
                 case_expectation_error IS NULL))
             """
           )
  end

  def down do
    drop constraint(:capture_evaluations, :capture_evaluations_expectation_check)
    drop constraint(:capture_evaluations, :capture_evaluations_contract_status_check)

    alter table(:capture_evaluations) do
      remove :case_expectation_error
      remove :case_expectation_results
      remove :case_expectation_status
      remove :case_expectation_fingerprint
      remove :case_expectation_schema_version
      remove :contract_status
    end

    execute(restore_case_version_guard())
    drop constraint(:case_versions, :case_versions_expectation_check)

    alter table(:case_versions) do
      remove :expectation_fingerprint
      remove :expectation
      remove :expectation_schema_version
    end
  end

  defp update_case_version_guard do
    """
    CREATE OR REPLACE FUNCTION prevent_case_version_update()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.case_key,
        NEW.name,
        NEW.position,
        NEW.status,
        NEW.input_variables,
        NEW.frozen_context,
        NEW.expectation_schema_version,
        NEW.expectation,
        NEW.expectation_fingerprint,
        NEW.fingerprint,
        NEW.monitor_version_id
      ) IS DISTINCT FROM ROW(
        OLD.case_key,
        OLD.name,
        OLD.position,
        OLD.status,
        OLD.input_variables,
        OLD.frozen_context,
        OLD.expectation_schema_version,
        OLD.expectation,
        OLD.expectation_fingerprint,
        OLD.fingerprint,
        OLD.monitor_version_id
      ) THEN
        RAISE EXCEPTION 'case version content is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp restore_case_version_guard do
    """
    CREATE OR REPLACE FUNCTION prevent_case_version_update()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.case_key,
        NEW.name,
        NEW.position,
        NEW.status,
        NEW.input_variables,
        NEW.frozen_context,
        NEW.fingerprint,
        NEW.monitor_version_id
      ) IS DISTINCT FROM ROW(
        OLD.case_key,
        OLD.name,
        OLD.position,
        OLD.status,
        OLD.input_variables,
        OLD.frozen_context,
        OLD.fingerprint,
        OLD.monitor_version_id
      ) THEN
        RAISE EXCEPTION 'case version content is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
