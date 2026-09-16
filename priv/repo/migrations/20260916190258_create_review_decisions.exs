defmodule SilentRegression.Repo.Migrations.CreateReviewDecisions do
  use Ecto.Migration

  def up do
    create table(:review_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :review_key, :string, null: false
      add :subject_kind, :string, null: false
      add :classification, :string, null: false
      add :action, :string, null: false, default: "none"
      add :rationale, :text
      add :reviewed_at, :utc_datetime_usec, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :restrict),
          null: false

      add :result_alert_id,
          references(:result_alerts, type: :binary_id, on_delete: :restrict)

      add :capture_observation_id,
          references(:capture_observations, type: :binary_id, on_delete: :restrict)

      add :capture_evaluation_id,
          references(:capture_evaluations, type: :binary_id, on_delete: :restrict)

      add :capture_rule_result_id,
          references(:capture_rule_results, type: :binary_id, on_delete: :restrict)

      add :contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :baseline_snapshot_id,
          references(:baseline_snapshots, type: :binary_id, on_delete: :restrict)

      add :reviewer_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :supersedes_id,
          references(:review_decisions, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:review_decisions, [:workspace_id, :review_key],
             where: "supersedes_id IS NULL",
             name: :review_decisions_one_root_index
           )

    create unique_index(:review_decisions, [:supersedes_id],
             where: "supersedes_id IS NOT NULL",
             name: :review_decisions_one_successor_index
           )

    create index(:review_decisions, [:workspace_id, :capture_run_id, :reviewed_at])
    create index(:review_decisions, [:result_alert_id, :reviewed_at])
    create index(:review_decisions, [:capture_observation_id, :reviewed_at])
    create index(:review_decisions, [:contract_version_id])
    create index(:review_decisions, [:classification])
    create index(:review_decisions, [:action])

    create constraint(:review_decisions, :review_decisions_subject_kind_check,
             check: "subject_kind IN ('alert', 'observation')"
           )

    create constraint(:review_decisions, :review_decisions_classification_check,
             check: """
             classification IN (
               'correct_pass', 'confirmed_regression', 'acceptable_variation',
               'contract_needs_revision', 'test_case_or_baseline_problem',
               'passed_but_should_have_failed', 'unsure', 'operational_anomaly'
             )
             """
           )

    create constraint(:review_decisions, :review_decisions_action_check,
             check: """
             action IN (
               'none', 'prompt_change', 'case_change', 'contract_revision',
               'provider_change', 'operational_follow_up'
             )
             """
           )

    create constraint(:review_decisions, :review_decisions_subject_check,
             check: """
             (subject_kind = 'alert' AND result_alert_id IS NOT NULL AND capture_observation_id IS NULL) OR
             (subject_kind = 'observation' AND result_alert_id IS NULL AND capture_observation_id IS NOT NULL)
             """
           )

    create constraint(:review_decisions, :review_decisions_rule_evaluation_check,
             check: "capture_rule_result_id IS NULL OR capture_evaluation_id IS NOT NULL"
           )

    create constraint(:review_decisions, :review_decisions_rationale_check,
             check: "rationale IS NULL OR (char_length(rationale) BETWEEN 1 AND 2000)"
           )

    create constraint(:review_decisions, :review_decisions_supersedes_check,
             check: "supersedes_id IS NULL OR supersedes_id <> id"
           )

    execute("""
    CREATE FUNCTION protect_review_decision_history()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'review decisions are append-only' USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER review_decisions_history_guard
    BEFORE UPDATE OR DELETE ON review_decisions
    FOR EACH ROW EXECUTE FUNCTION protect_review_decision_history();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS review_decisions_history_guard ON review_decisions")
    execute("DROP FUNCTION IF EXISTS protect_review_decision_history()")
    drop table(:review_decisions)
  end
end
