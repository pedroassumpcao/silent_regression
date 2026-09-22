defmodule SilentRegression.Repo.Migrations.CreateGuidedSetupDrafts do
  use Ecto.Migration

  def change do
    create table(:guided_setup_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :monitor_id, references(:monitors, type: :binary_id, on_delete: :delete_all)
      add :schema_version, :integer, null: false, default: 1
      add :recipe, :string, null: false, default: "routing"
      add :recipe_version, :integer, null: false, default: 1
      add :revision, :integer, null: false, default: 1
      add :raw, :map, null: false
      add :reviews, :map, null: false, default: %{}
      add :sealed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:guided_setup_drafts, [:workspace_id, :updated_at])
    create unique_index(:guided_setup_drafts, [:monitor_id])

    create constraint(:guided_setup_drafts, :guided_setup_draft_shape,
             check:
               "schema_version = 1 AND recipe = 'routing' AND recipe_version = 1 AND revision > 0 AND octet_length(raw::text) <= 300000 AND octet_length(reviews::text) <= 100000 AND ((monitor_id IS NULL AND sealed_at IS NULL) OR (monitor_id IS NOT NULL AND sealed_at IS NOT NULL))"
           )

    execute(
      """
      CREATE FUNCTION protect_sealed_guided_setup() RETURNS trigger AS $$
      BEGIN
        IF OLD.sealed_at IS NOT NULL AND
           ROW(NEW.workspace_id, NEW.monitor_id, NEW.raw, NEW.reviews, NEW.revision, NEW.schema_version, NEW.recipe, NEW.recipe_version, NEW.sealed_at)
           IS DISTINCT FROM
           ROW(OLD.workspace_id, OLD.monitor_id, OLD.raw, OLD.reviews, OLD.revision, OLD.schema_version, OLD.recipe, OLD.recipe_version, OLD.sealed_at) THEN
          RAISE EXCEPTION 'sealed guided setup is immutable' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION protect_sealed_guided_setup()"
    )

    execute(
      "CREATE TRIGGER guided_setup_sealed_immutable BEFORE UPDATE ON guided_setup_drafts FOR EACH ROW EXECUTE FUNCTION protect_sealed_guided_setup()",
      "DROP TRIGGER guided_setup_sealed_immutable ON guided_setup_drafts"
    )
  end
end
