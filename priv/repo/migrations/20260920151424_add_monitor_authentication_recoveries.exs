defmodule SilentRegression.Repo.Migrations.AddMonitorAuthenticationRecoveries do
  use Ecto.Migration

  def up do
    alter table(:provider_credential_model_validations) do
      modify :validated_at, :utc_datetime_usec, null: false
    end

    drop constraint(:capture_runs, :capture_runs_kind_check)

    create constraint(:capture_runs, :capture_runs_kind_check,
             check: "kind IN ('baseline', 'manual', 'scheduled', 'authentication_probe')"
           )

    create table(:monitor_authentication_recoveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :epoch, :integer, null: false
      add :requested_model, :string, null: false
      add :credential_validated_at, :utc_datetime_usec, null: false
      add :validation_request_id, :string
      add :authorized_at, :utc_datetime_usec, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_credential_id,
          references(:provider_credentials, type: :binary_id, on_delete: :restrict),
          null: false

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :authorized_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:monitor_authentication_recoveries, [:monitor_id, :epoch])
    create unique_index(:monitor_authentication_recoveries, [:capture_run_id])

    create index(
             :monitor_authentication_recoveries,
             [:workspace_id, :monitor_id, :authorized_at]
           )

    create constraint(
             :monitor_authentication_recoveries,
             :monitor_authentication_recoveries_epoch_check,
             check: "epoch > 0"
           )

    create constraint(
             :monitor_authentication_recoveries,
             :monitor_authentication_recoveries_requested_model_check,
             check: "char_length(requested_model) BETWEEN 1 AND 200"
           )

    execute("""
    CREATE FUNCTION protect_monitor_authentication_recovery()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'monitor authentication recovery history is immutable'
        USING ERRCODE = '23514';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER monitor_authentication_recoveries_immutable
    BEFORE UPDATE ON monitor_authentication_recoveries
    FOR EACH ROW EXECUTE FUNCTION protect_monitor_authentication_recovery();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER monitor_authentication_recoveries_immutable ON monitor_authentication_recoveries"
    )

    execute("DROP FUNCTION protect_monitor_authentication_recovery()")

    drop table(:monitor_authentication_recoveries)

    execute("DELETE FROM capture_runs WHERE kind = 'authentication_probe'")

    drop constraint(:capture_runs, :capture_runs_kind_check)

    create constraint(:capture_runs, :capture_runs_kind_check,
             check: "kind IN ('baseline', 'manual', 'scheduled')"
           )

    alter table(:provider_credential_model_validations) do
      modify :validated_at, :utc_datetime, null: false
    end
  end
end
