defmodule SilentRegression.Repo.Migrations.CreatePilotPoliciesAndRateLimitBuckets do
  use Ecto.Migration

  def up do
    create table(:pilot_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :daily_run_limit, :integer, null: false, default: 20
      add :daily_call_limit, :integer, null: false, default: 200
      add :per_run_call_limit, :integer, null: false, default: 200

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pilot_policies, [:workspace_id])

    create constraint(:pilot_policies, :pilot_policies_limits_check,
             check: """
             daily_run_limit > 0 AND daily_run_limit <= 1000 AND
             daily_call_limit > 0 AND daily_call_limit <= 100000 AND
             per_run_call_limit > 0 AND per_run_call_limit <= daily_call_limit
             """
           )

    execute("""
    INSERT INTO pilot_policies (
      id, workspace_id, daily_run_limit, daily_call_limit, per_run_call_limit,
      inserted_at, updated_at
    )
    SELECT gen_random_uuid(), id, 20, 200, 200, NOW(), NOW()
    FROM workspaces
    """)

    create table(:rate_limit_buckets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :subject_hash, :binary, null: false
      add :window_started_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :hits, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:rate_limit_buckets, [:action, :subject_hash, :window_started_at])
    create index(:rate_limit_buckets, [:expires_at])

    create constraint(:rate_limit_buckets, :rate_limit_buckets_action_check,
             check:
               "action IN ('login', 'invitation_acceptance', 'credential_validation', 'run_authorization')"
           )

    create constraint(:rate_limit_buckets, :rate_limit_buckets_hash_check,
             check: "octet_length(subject_hash) = 32"
           )

    create constraint(:rate_limit_buckets, :rate_limit_buckets_hits_check, check: "hits > 0")

    create constraint(:rate_limit_buckets, :rate_limit_buckets_window_check,
             check: "expires_at > window_started_at"
           )
  end

  def down do
    drop table(:rate_limit_buckets)
    drop table(:pilot_policies)
  end
end
