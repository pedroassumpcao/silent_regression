defmodule SilentRegression.Repo.Migrations.BindReviewsToCorrections do
  use Ecto.Migration

  def up do
    alter table(:result_alerts) do
      add :resolution_review_decision_id,
          references(:review_decisions, type: :binary_id, on_delete: :restrict)
    end

    create index(:result_alerts, [:resolution_review_decision_id])

    create table(:review_contract_revision_origins, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :review_decision_id,
          references(:review_decisions, type: :binary_id, on_delete: :restrict),
          null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :actor_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:review_contract_revision_origins, [:review_decision_id])
    create index(:review_contract_revision_origins, [:contract_version_id])

    execute("""
    CREATE FUNCTION protect_review_contract_revision_origin()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (
          SELECT 1
          FROM review_decisions AS decision
          JOIN contract_versions AS contract
            ON contract.id = NEW.contract_version_id
          WHERE decision.id = NEW.review_decision_id
            AND decision.workspace_id = contract.workspace_id
            AND decision.monitor_id = contract.monitor_id
        ) THEN
          RAISE EXCEPTION 'review and contract revision provenance must match' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'review contract revision origins are immutable' USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER review_contract_revision_origins_guard
    BEFORE INSERT OR UPDATE OR DELETE ON review_contract_revision_origins
    FOR EACH ROW EXECUTE FUNCTION protect_review_contract_revision_origin();
    """)

    execute("""
    CREATE OR REPLACE FUNCTION protect_result_alert()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.identity_key, NEW.category, NEW.severity, NEW.code, NEW.title,
        NEW.explanation, NEW.evidence, NEW.opened_at, NEW.workspace_id, NEW.monitor_id,
        NEW.capture_run_id, NEW.capture_evaluation_id
      ) IS DISTINCT FROM ROW(
        OLD.identity_key, OLD.category, OLD.severity, OLD.code, OLD.title,
        OLD.explanation, OLD.evidence, OLD.opened_at, OLD.workspace_id, OLD.monitor_id,
        OLD.capture_run_id, OLD.capture_evaluation_id
      ) THEN
        RAISE EXCEPTION 'result alert evidence is immutable' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'acknowledged') THEN
        RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'acknowledged' AND NEW.status NOT IN ('acknowledged', 'resolved') THEN
        RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'resolved' AND NEW.status <> 'resolved' THEN
        RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
      END IF;

      IF OLD.status <> 'resolved' AND NEW.status = 'resolved' AND
         NEW.resolution_review_decision_id IS NULL THEN
        RAISE EXCEPTION 'review decision is required for resolution' USING ERRCODE = '23514';
      END IF;

      IF OLD.status <> 'resolved' AND NEW.status = 'resolved' AND NOT EXISTS (
        SELECT 1
        FROM review_decisions AS decision
        WHERE decision.id = NEW.resolution_review_decision_id
          AND decision.workspace_id = NEW.workspace_id
          AND decision.result_alert_id = NEW.id
      ) THEN
        RAISE EXCEPTION 'resolution review decision does not belong to alert' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'resolved' AND
         NEW.resolution_review_decision_id IS DISTINCT FROM OLD.resolution_review_decision_id THEN
        RAISE EXCEPTION 'alert resolution decision is immutable' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION protect_result_alert()
    RETURNS trigger AS $$
    BEGIN
      IF ROW(
        NEW.identity_key, NEW.category, NEW.severity, NEW.code, NEW.title,
        NEW.explanation, NEW.evidence, NEW.opened_at, NEW.workspace_id, NEW.monitor_id,
        NEW.capture_run_id, NEW.capture_evaluation_id
      ) IS DISTINCT FROM ROW(
        OLD.identity_key, OLD.category, OLD.severity, OLD.code, OLD.title,
        OLD.explanation, OLD.evidence, OLD.opened_at, OLD.workspace_id, OLD.monitor_id,
        OLD.capture_run_id, OLD.capture_evaluation_id
      ) THEN
        RAISE EXCEPTION 'result alert evidence is immutable' USING ERRCODE = '23514';
      END IF;

      IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'acknowledged') THEN
        RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'acknowledged' AND NEW.status NOT IN ('acknowledged', 'resolved') THEN
        RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
      ELSIF OLD.status = 'resolved' AND NEW.status <> 'resolved' THEN
        RAISE EXCEPTION 'invalid result alert lifecycle transition' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute(
      "DROP TRIGGER IF EXISTS review_contract_revision_origins_guard ON review_contract_revision_origins"
    )

    execute("DROP FUNCTION IF EXISTS protect_review_contract_revision_origin()")
    drop table(:review_contract_revision_origins)
    drop index(:result_alerts, [:resolution_review_decision_id])

    alter table(:result_alerts) do
      remove :resolution_review_decision_id
    end
  end
end
