defmodule SilentRegression.Repo.Migrations.CreateProviderCredentials do
  use Ecto.Migration

  def change do
    create table(:provider_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :label, :string, null: false
      add :encrypted_secret, :binary, null: false
      add :secret_suffix, :string, null: false
      add :status, :string, null: false, default: "pending_validation"
      add :last_validation_status, :string
      add :last_failure_category, :string
      add :last_validated_at, :utc_datetime
      add :last_requested_model, :string
      add :last_returned_model, :string
      add :last_provider_request_id, :string
      add :last_validation_attempts, :integer
      add :revoked_at, :utc_datetime
      add :superseded_at, :utc_datetime

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: false

      add :revoked_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :supersedes_id,
          references(:provider_credentials, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:provider_credentials, [:workspace_id, :status, :inserted_at])
    create index(:provider_credentials, [:workspace_id, :provider])
    create unique_index(:provider_credentials, [:supersedes_id])

    create constraint(:provider_credentials, :provider_credentials_provider_check,
             check: "provider IN ('openai', 'anthropic')"
           )

    create constraint(:provider_credentials, :provider_credentials_status_check,
             check:
               "status IN ('pending_validation', 'valid', 'invalid', 'revoked', 'superseded')"
           )

    create constraint(:provider_credentials, :provider_credentials_validation_status_check,
             check:
               "last_validation_status IS NULL OR last_validation_status IN ('succeeded', 'failed')"
           )

    create constraint(:provider_credentials, :provider_credentials_failure_category_check,
             check:
               "last_failure_category IS NULL OR last_failure_category IN ('authentication', 'authorization', 'rate_limited', 'transport', 'provider', 'malformed_response', 'model_mismatch')"
           )

    create constraint(:provider_credentials, :provider_credentials_attempts_check,
             check: "last_validation_attempts IS NULL OR last_validation_attempts > 0"
           )
  end
end
