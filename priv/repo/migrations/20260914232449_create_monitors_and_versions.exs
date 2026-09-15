defmodule SilentRegression.Repo.Migrations.CreateMonitorsAndVersions do
  use Ecto.Migration

  def change do
    create table(:monitors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :state, :string, null: false, default: "draft"
      add :state_changed_at, :utc_datetime, null: false
      add :archived_at, :utc_datetime

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:monitors, [:workspace_id, :state, :inserted_at])

    create constraint(:monitors, :monitors_state_check,
             check:
               "state IN ('draft', 'validating', 'ready', 'baseline_pending', 'active', 'paused', 'archived')"
           )

    create constraint(:monitors, :monitors_archived_at_check,
             check:
               "(state = 'archived' AND archived_at IS NOT NULL) OR (state <> 'archived' AND archived_at IS NULL)"
           )

    create table(:monitor_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version, :integer, null: false
      add :schema_version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "draft"
      add :provider, :string, null: false
      add :requested_model, :string, null: false
      add :system_prompt, :text, null: false, default: ""
      add :user_prompt_template, :text, null: false
      add :response_format, :map, null: false
      add :generation_config, :map, null: false
      add :case_set_fingerprint, :string, size: 64, null: false
      add :fingerprint, :string, size: 64, null: false
      add :activated_at, :utc_datetime
      add :superseded_at, :utc_datetime

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :predecessor_id,
          references(:monitor_versions, type: :binary_id)

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:monitor_versions, [:monitor_id, :version])
    create index(:monitor_versions, [:monitor_id, :fingerprint])

    create unique_index(:monitor_versions, [:monitor_id],
             where: "status = 'draft'",
             name: :monitor_versions_one_draft_index
           )

    create unique_index(:monitor_versions, [:monitor_id],
             where: "status = 'active'",
             name: :monitor_versions_one_active_index
           )

    create constraint(:monitor_versions, :monitor_versions_version_check, check: "version > 0")

    create constraint(:monitor_versions, :monitor_versions_schema_version_check,
             check: "schema_version = 1"
           )

    create constraint(:monitor_versions, :monitor_versions_status_check,
             check: "status IN ('draft', 'active', 'superseded')"
           )

    create constraint(:monitor_versions, :monitor_versions_provider_check,
             check: "provider IN ('openai', 'anthropic')"
           )

    create constraint(:monitor_versions, :monitor_versions_fingerprint_check,
             check: "case_set_fingerprint ~ '^[0-9a-f]{64}$' AND fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:monitor_versions, :monitor_versions_lifecycle_timestamps_check,
             check: """
             (status = 'draft' AND activated_at IS NULL AND superseded_at IS NULL) OR
             (status = 'active' AND activated_at IS NOT NULL AND superseded_at IS NULL) OR
             (status = 'superseded' AND superseded_at IS NOT NULL)
             """
           )

    create table(:case_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :case_key, :string, null: false
      add :name, :string, null: false
      add :position, :integer, null: false
      add :status, :string, null: false, default: "active"
      add :input_variables, :map, null: false, default: %{}
      add :frozen_context, :text, null: false, default: ""
      add :fingerprint, :string, size: 64, null: false

      add :monitor_version_id,
          references(:monitor_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:case_versions, [:monitor_version_id, :case_key])
    create unique_index(:case_versions, [:monitor_version_id, :position])
    create index(:case_versions, [:monitor_version_id, :status, :position])

    create constraint(:case_versions, :case_versions_position_check, check: "position >= 0")

    create constraint(:case_versions, :case_versions_status_check,
             check: "status IN ('active', 'disabled')"
           )

    create constraint(:case_versions, :case_versions_fingerprint_check,
             check: "fingerprint ~ '^[0-9a-f]{64}$'"
           )

    alter table(:monitors) do
      add :active_version_id,
          references(:monitor_versions, type: :binary_id, on_delete: :nilify_all)

      add :draft_version_id,
          references(:monitor_versions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:monitors, [:active_version_id])
    create index(:monitors, [:draft_version_id])

    execute(
      """
      CREATE FUNCTION prevent_monitor_version_content_update()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.version,
          NEW.schema_version,
          NEW.provider,
          NEW.requested_model,
          NEW.system_prompt,
          NEW.user_prompt_template,
          NEW.response_format,
          NEW.generation_config,
          NEW.case_set_fingerprint,
          NEW.fingerprint,
          NEW.monitor_id,
          NEW.predecessor_id
        ) IS DISTINCT FROM ROW(
          OLD.version,
          OLD.schema_version,
          OLD.provider,
          OLD.requested_model,
          OLD.system_prompt,
          OLD.user_prompt_template,
          OLD.response_format,
          OLD.generation_config,
          OLD.case_set_fingerprint,
          OLD.fingerprint,
          OLD.monitor_id,
          OLD.predecessor_id
        ) THEN
          RAISE EXCEPTION 'monitor version content is immutable' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS prevent_monitor_version_content_update()"
    )

    execute(
      """
      CREATE TRIGGER monitor_versions_content_immutable
      BEFORE UPDATE ON monitor_versions
      FOR EACH ROW EXECUTE FUNCTION prevent_monitor_version_content_update();
      """,
      "DROP TRIGGER IF EXISTS monitor_versions_content_immutable ON monitor_versions"
    )

    execute(
      """
      CREATE FUNCTION prevent_case_version_update()
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
      """,
      "DROP FUNCTION IF EXISTS prevent_case_version_update()"
    )

    execute(
      """
      CREATE TRIGGER case_versions_immutable
      BEFORE UPDATE ON case_versions
      FOR EACH ROW EXECUTE FUNCTION prevent_case_version_update();
      """,
      "DROP TRIGGER IF EXISTS case_versions_immutable ON case_versions"
    )
  end
end
