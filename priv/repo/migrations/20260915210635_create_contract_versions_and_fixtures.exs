defmodule SilentRegression.Repo.Migrations.CreateContractVersionsAndFixtures do
  use Ecto.Migration

  def change do
    create table(:contract_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version, :integer, null: false
      add :schema_version, :integer, null: false, default: 1
      add :evaluator_engine_version, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :template_key, :string, null: false
      add :template_usage, :map, null: false
      add :assistance_mode, :string, null: false, default: "self_serve"
      add :root, :map, null: false
      add :contract_fingerprint, :string, size: 64, null: false
      add :fixture_set_fingerprint, :string, size: 64, null: false
      add :fingerprint, :string, size: 64, null: false
      add :approved_at, :utc_datetime
      add :retired_at, :utc_datetime

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_version_id,
          references(:monitor_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :predecessor_id,
          references(:contract_versions, type: :binary_id)

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :approved_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contract_versions, [:monitor_id, :version])
    create index(:contract_versions, [:workspace_id, :monitor_id, :status])
    create index(:contract_versions, [:monitor_version_id])
    create index(:contract_versions, [:fingerprint])

    create unique_index(:contract_versions, [:monitor_id],
             where: "status = 'draft'",
             name: :contract_versions_one_draft_index
           )

    create unique_index(:contract_versions, [:monitor_id],
             where: "status = 'approved'",
             name: :contract_versions_one_approved_index
           )

    create constraint(:contract_versions, :contract_versions_version_check, check: "version > 0")

    create constraint(:contract_versions, :contract_versions_schema_version_check,
             check: "schema_version = 1"
           )

    create constraint(:contract_versions, :contract_versions_status_check,
             check: "status IN ('draft', 'approved', 'retired')"
           )

    create constraint(:contract_versions, :contract_versions_assistance_mode_check,
             check: "assistance_mode IN ('self_serve', 'founder_assisted', 'codex_assisted')"
           )

    create constraint(:contract_versions, :contract_versions_fingerprints_check,
             check: """
             contract_fingerprint ~ '^[0-9a-f]{64}$' AND
             fixture_set_fingerprint ~ '^[0-9a-f]{64}$' AND
             fingerprint ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:contract_versions, :contract_versions_lifecycle_check,
             check: """
             (status = 'draft' AND approved_at IS NULL AND retired_at IS NULL) OR
             (status = 'approved' AND approved_at IS NOT NULL AND retired_at IS NULL) OR
             (status = 'retired' AND approved_at IS NOT NULL AND retired_at IS NOT NULL)
             """
           )

    create table(:contract_fixtures, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :position, :integer, null: false
      add :output_text, :text, null: false
      add :expected_status, :string, null: false
      add :expected_rule_statuses, :map, null: false, default: %{}
      add :fingerprint, :string, size: 64, null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contract_fixtures, [:contract_version_id, :position])
    create index(:contract_fixtures, [:contract_version_id, :expected_status])

    create constraint(:contract_fixtures, :contract_fixtures_position_check,
             check: "position >= 0"
           )

    create constraint(:contract_fixtures, :contract_fixtures_expected_status_check,
             check: "expected_status IN ('pass', 'fail')"
           )

    create constraint(:contract_fixtures, :contract_fixtures_fingerprint_check,
             check: "fingerprint ~ '^[0-9a-f]{64}$'"
           )

    execute(
      """
      CREATE FUNCTION protect_contract_version_history()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.status <> 'draft' AND ROW(
          NEW.version,
          NEW.schema_version,
          NEW.evaluator_engine_version,
          NEW.template_key,
          NEW.template_usage,
          NEW.assistance_mode,
          NEW.root,
          NEW.contract_fingerprint,
          NEW.fixture_set_fingerprint,
          NEW.fingerprint,
          NEW.workspace_id,
          NEW.monitor_id,
          NEW.monitor_version_id,
          NEW.predecessor_id
        ) IS DISTINCT FROM ROW(
          OLD.version,
          OLD.schema_version,
          OLD.evaluator_engine_version,
          OLD.template_key,
          OLD.template_usage,
          OLD.assistance_mode,
          OLD.root,
          OLD.contract_fingerprint,
          OLD.fixture_set_fingerprint,
          OLD.fingerprint,
          OLD.workspace_id,
          OLD.monitor_id,
          OLD.monitor_version_id,
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
      """,
      "DROP FUNCTION IF EXISTS protect_contract_version_history()"
    )

    execute(
      """
      CREATE TRIGGER contract_versions_history_guard
      BEFORE UPDATE ON contract_versions
      FOR EACH ROW EXECUTE FUNCTION protect_contract_version_history();
      """,
      "DROP TRIGGER IF EXISTS contract_versions_history_guard ON contract_versions"
    )

    execute(
      """
      CREATE FUNCTION protect_contract_fixture_history()
      RETURNS trigger AS $$
      DECLARE
        parent_id uuid;
        parent_status text;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          parent_id := OLD.contract_version_id;
        ELSE
          parent_id := NEW.contract_version_id;
        END IF;

        SELECT status INTO parent_status
        FROM contract_versions
        WHERE id = parent_id;

        IF parent_status IS NOT NULL AND parent_status <> 'draft' THEN
          RAISE EXCEPTION 'approved contract fixtures are immutable' USING ERRCODE = '23514';
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS protect_contract_fixture_history()"
    )

    execute(
      """
      CREATE TRIGGER contract_fixtures_history_guard
      BEFORE INSERT OR UPDATE OR DELETE ON contract_fixtures
      FOR EACH ROW EXECUTE FUNCTION protect_contract_fixture_history();
      """,
      "DROP TRIGGER IF EXISTS contract_fixtures_history_guard ON contract_fixtures"
    )
  end
end
