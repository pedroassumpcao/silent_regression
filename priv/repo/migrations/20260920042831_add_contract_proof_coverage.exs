defmodule SilentRegression.Repo.Migrations.AddContractProofCoverage do
  use Ecto.Migration

  def up do
    alter table(:contract_versions) do
      add :proof_schema_version, :string
      add :proof_fingerprint, :string, size: 64
    end

    create constraint(:contract_versions, :contract_versions_proof_fingerprint_check,
             check: "proof_fingerprint IS NULL OR proof_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:contract_versions, :contract_versions_proof_pair_check,
             check: "(proof_schema_version IS NULL) = (proof_fingerprint IS NULL)"
           )

    create table(:contract_coverage_waivers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :rule_id, :string, null: false
      add :rule_fingerprint, :string, size: 64, null: false
      add :rationale, :text, null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :waived_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contract_coverage_waivers, [:contract_version_id, :rule_id])
    create index(:contract_coverage_waivers, [:waived_by_user_id])

    create constraint(:contract_coverage_waivers, :contract_coverage_waivers_rule_id_check,
             check: "rule_id ~ '^[a-z][a-z0-9_-]{0,79}$'"
           )

    create constraint(
             :contract_coverage_waivers,
             :contract_coverage_waivers_rule_fingerprint_check,
             check: "rule_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:contract_coverage_waivers, :contract_coverage_waivers_rationale_check,
             check: "char_length(btrim(rationale)) BETWEEN 20 AND 1000"
           )

    execute(contract_version_guard())
    execute(coverage_waiver_guard())

    execute("""
    CREATE TRIGGER contract_coverage_waivers_history_guard
    BEFORE INSERT OR UPDATE OR DELETE ON contract_coverage_waivers
    FOR EACH ROW EXECUTE FUNCTION protect_contract_coverage_waiver_history();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS contract_coverage_waivers_history_guard ON contract_coverage_waivers"
    )

    execute("DROP FUNCTION IF EXISTS protect_contract_coverage_waiver_history()")
    drop table(:contract_coverage_waivers)

    execute(legacy_contract_version_guard())

    drop constraint(:contract_versions, :contract_versions_proof_pair_check)
    drop constraint(:contract_versions, :contract_versions_proof_fingerprint_check)

    alter table(:contract_versions) do
      remove :proof_fingerprint
      remove :proof_schema_version
    end
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

  defp coverage_waiver_guard do
    """
    CREATE FUNCTION protect_contract_coverage_waiver_history()
    RETURNS trigger AS $$
    DECLARE parent_id uuid; parent_status text;
    BEGIN
      IF current_setting('silent_regression.customer_purge', true) = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
      END IF;

      IF TG_OP = 'DELETE' THEN parent_id := OLD.contract_version_id;
      ELSE parent_id := NEW.contract_version_id;
      END IF;

      SELECT status INTO parent_status FROM contract_versions WHERE id = parent_id;

      IF parent_status IS NOT NULL AND parent_status <> 'draft' THEN
        RAISE EXCEPTION 'approved contract coverage waivers are immutable' USING ERRCODE = '23514';
      END IF;

      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
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
        NEW.fixture_set_fingerprint, NEW.fingerprint, NEW.workspace_id, NEW.monitor_id,
        NEW.monitor_version_id, NEW.predecessor_id
      ) IS DISTINCT FROM ROW(
        OLD.version, OLD.schema_version, OLD.evaluator_engine_version, OLD.template_key,
        OLD.template_usage, OLD.assistance_mode, OLD.root, OLD.contract_fingerprint,
        OLD.fixture_set_fingerprint, OLD.fingerprint, OLD.workspace_id, OLD.monitor_id,
        OLD.monitor_version_id, OLD.predecessor_id
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
