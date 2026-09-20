defmodule SilentRegression.Repo.Migrations.AddSuccessorMonitorSetups do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:monitor_setups, [:monitor_id],
                     name: :monitor_setups_monitor_id_index
                   )

    alter table(:monitor_setups) do
      add :source_monitor_version_id,
          references(:monitor_versions, type: :binary_id)

      add :motivating_review_decision_id,
          references(:review_decisions, type: :binary_id)
    end

    create index(:monitor_setups, [:source_monitor_version_id])
    create index(:monitor_setups, [:motivating_review_decision_id])

    create unique_index(:monitor_setups, [:monitor_id],
             where: "status = 'in_progress'",
             name: :monitor_setups_one_in_progress_index
           )

    create constraint(:monitor_setups, :monitor_setups_successor_origin_check,
             check:
               "motivating_review_decision_id IS NULL OR source_monitor_version_id IS NOT NULL"
           )

    execute("""
    CREATE FUNCTION protect_monitor_setup_origin()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(NEW.source_monitor_version_id, NEW.motivating_review_decision_id) IS DISTINCT FROM
         ROW(OLD.source_monitor_version_id, OLD.motivating_review_decision_id) THEN
        RAISE EXCEPTION 'monitor setup origin is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER monitor_setups_protect_origin
    BEFORE UPDATE ON monitor_setups
    FOR EACH ROW EXECUTE FUNCTION protect_monitor_setup_origin();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS monitor_setups_protect_origin ON monitor_setups")
    execute("DROP FUNCTION IF EXISTS protect_monitor_setup_origin()")
    execute("DELETE FROM monitor_setups WHERE source_monitor_version_id IS NOT NULL")

    drop constraint(:monitor_setups, :monitor_setups_successor_origin_check)

    drop_if_exists index(:monitor_setups, [:monitor_id],
                     name: :monitor_setups_one_in_progress_index
                   )

    drop_if_exists index(:monitor_setups, [:motivating_review_decision_id])
    drop_if_exists index(:monitor_setups, [:source_monitor_version_id])

    alter table(:monitor_setups) do
      remove :motivating_review_decision_id
      remove :source_monitor_version_id
    end

    create unique_index(:monitor_setups, [:monitor_id], name: :monitor_setups_monitor_id_index)
  end
end
