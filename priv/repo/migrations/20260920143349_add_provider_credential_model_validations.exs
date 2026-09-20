defmodule SilentRegression.Repo.Migrations.AddProviderCredentialModelValidations do
  use Ecto.Migration

  def change do
    create table(:provider_credential_model_validations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :requested_model, :string, null: false
      add :returned_model, :string
      add :status, :string, null: false
      add :failure_category, :string
      add :provider_request_id, :string
      add :attempts, :integer, null: false
      add :validated_at, :utc_datetime, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider_credential_id,
          references(:provider_credentials, type: :binary_id, on_delete: :delete_all),
          null: false

      add :validated_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :provider_credential_model_validations,
             [:provider_credential_id, :requested_model],
             name: :provider_credential_model_validations_credential_model_index
           )

    create index(:provider_credential_model_validations, [:workspace_id, :status])

    create constraint(
             :provider_credential_model_validations,
             :provider_credential_model_validations_status_check,
             check: "status IN ('succeeded', 'failed')"
           )

    create constraint(
             :provider_credential_model_validations,
             :provider_credential_model_validations_failure_category_check,
             check:
               "failure_category IS NULL OR failure_category IN ('authentication', 'authorization', 'rate_limited', 'transport', 'provider', 'malformed_response', 'model_mismatch')"
           )

    create constraint(
             :provider_credential_model_validations,
             :provider_credential_model_validations_attempts_check,
             check: "attempts > 0"
           )

    create constraint(
             :provider_credential_model_validations,
             :provider_credential_model_validations_result_check,
             check: """
             (status = 'succeeded' AND returned_model = requested_model AND failure_category IS NULL) OR
             (status = 'failed' AND failure_category IS NOT NULL)
             """
           )

    execute(
      """
      INSERT INTO provider_credential_model_validations (
        id,
        requested_model,
        returned_model,
        status,
        failure_category,
        provider_request_id,
        attempts,
        validated_at,
        workspace_id,
        provider_credential_id,
        validated_by_user_id,
        inserted_at,
        updated_at
      )
      SELECT
        gen_random_uuid(),
        last_requested_model,
        last_returned_model,
        CASE
          WHEN last_validation_status = 'succeeded' AND last_returned_model = last_requested_model
            THEN 'succeeded'
          ELSE 'failed'
        END,
        CASE
          WHEN last_validation_status = 'succeeded' AND last_returned_model = last_requested_model
            THEN NULL
          WHEN last_validation_status = 'succeeded'
            THEN 'model_mismatch'
          ELSE COALESCE(last_failure_category, 'provider')
        END,
        last_provider_request_id,
        COALESCE(last_validation_attempts, 1),
        COALESCE(last_validated_at, updated_at),
        workspace_id,
        id,
        created_by_user_id,
        COALESCE(last_validated_at, inserted_at),
        COALESCE(last_validated_at, updated_at)
      FROM provider_credentials
      WHERE last_requested_model IS NOT NULL
      """,
      "DELETE FROM provider_credential_model_validations"
    )
  end
end
