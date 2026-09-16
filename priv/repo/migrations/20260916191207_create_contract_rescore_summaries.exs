defmodule SilentRegression.Repo.Migrations.CreateContractRescoreSummaries do
  use Ecto.Migration

  def up do
    create table(:contract_rescore_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :observation_count, :integer, null: false
      add :pass_count, :integer, null: false
      add :fail_count, :integer, null: false
      add :evaluator_error_count, :integer, null: false
      add :interpretation_changed, :boolean, null: false
      add :rescored_at, :utc_datetime_usec, null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :predecessor_contract_version_id,
          references(:contract_versions, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:contract_rescore_summaries, [:contract_version_id])
    create index(:contract_rescore_summaries, [:predecessor_contract_version_id])

    create constraint(:contract_rescore_summaries, :contract_rescore_summaries_counts_check,
             check: """
             observation_count >= 0 AND pass_count >= 0 AND fail_count >= 0 AND
             evaluator_error_count >= 0 AND
             observation_count = pass_count + fail_count + evaluator_error_count
             """
           )

    execute("""
    CREATE FUNCTION protect_contract_rescore_summary()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'contract rescore summaries are immutable' USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER contract_rescore_summaries_guard
    BEFORE UPDATE OR DELETE ON contract_rescore_summaries
    FOR EACH ROW EXECUTE FUNCTION protect_contract_rescore_summary();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS contract_rescore_summaries_guard ON contract_rescore_summaries"
    )

    execute("DROP FUNCTION IF EXISTS protect_contract_rescore_summary()")
    drop table(:contract_rescore_summaries)
  end
end
