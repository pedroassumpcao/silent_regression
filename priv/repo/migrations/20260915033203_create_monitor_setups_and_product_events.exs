defmodule SilentRegression.Repo.Migrations.CreateMonitorSetupsAndProductEvents do
  use Ecto.Migration

  def change do
    alter table(:monitors) do
      add :provider_credential_id,
          references(:provider_credentials, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:monitors, [:provider_credential_id])

    create table(:monitor_setups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "in_progress"
      add :provider, :string
      add :requested_model, :string
      add :system_prompt, :text, null: false, default: ""
      add :user_prompt_template, :text, null: false, default: ""
      add :response_format, :map, null: false, default: %{"type" => "text"}

      add :generation_config, :map,
        null: false,
        default: %{"max_output_tokens" => 512}

      add :cases, :map, null: false, default: %{"items" => []}
      add :completed_at, :utc_datetime

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_credential_id,
          references(:provider_credentials, type: :binary_id, on_delete: :nilify_all)

      add :completed_monitor_version_id,
          references(:monitor_versions, type: :binary_id, on_delete: :nilify_all)

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:monitor_setups, [:monitor_id])
    create index(:monitor_setups, [:workspace_id, :status, :updated_at])
    create index(:monitor_setups, [:provider_credential_id])

    create constraint(:monitor_setups, :monitor_setups_status_check,
             check: "status IN ('in_progress', 'completed')"
           )

    create constraint(:monitor_setups, :monitor_setups_provider_check,
             check: "provider IS NULL OR provider IN ('openai', 'anthropic')"
           )

    create constraint(:monitor_setups, :monitor_setups_completion_check,
             check: """
             (status = 'in_progress' AND completed_at IS NULL AND completed_monitor_version_id IS NULL) OR
             (status = 'completed' AND completed_at IS NOT NULL AND completed_monitor_version_id IS NOT NULL)
             """
           )

    create table(:product_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id
      add :properties, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:product_events, [:workspace_id, :occurred_at])
    create index(:product_events, [:target_type, :target_id])

    create constraint(:product_events, :product_events_name_check,
             check: """
             name IN (
               'monitor_setup.started',
               'monitor_setup.step_completed',
               'monitor_setup.left',
               'monitor_setup.completed'
             )
             """
           )

    execute(
      """
      CREATE FUNCTION prevent_product_event_content_update()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.name,
          NEW.target_type,
          NEW.target_id,
          NEW.properties,
          NEW.occurred_at,
          NEW.workspace_id
        ) IS DISTINCT FROM ROW(
          OLD.name,
          OLD.target_type,
          OLD.target_id,
          OLD.properties,
          OLD.occurred_at,
          OLD.workspace_id
        ) THEN
          RAISE EXCEPTION 'product event content is immutable' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS prevent_product_event_content_update()"
    )

    execute(
      """
      CREATE TRIGGER product_events_content_immutable
      BEFORE UPDATE ON product_events
      FOR EACH ROW EXECUTE FUNCTION prevent_product_event_content_update();
      """,
      "DROP TRIGGER IF EXISTS product_events_content_immutable ON product_events"
    )
  end
end
