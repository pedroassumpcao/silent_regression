defmodule SilentRegression.ProviderCredentials.ModelValidation do
  @moduledoc """
  Latest safe provider validation result for one credential and exact requested model.

  This table is mutable current state. Append-only audit events retain each validation attempt,
  while capture and reference records retain the credential identity used for execution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Providers.{CredentialValidation, Failure}
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @failure_categories [
    :authentication,
    :authorization,
    :rate_limited,
    :transport,
    :provider,
    :malformed_response,
    :model_mismatch
  ]

  schema "provider_credential_model_validations" do
    field :requested_model, :string
    field :returned_model, :string
    field :status, Ecto.Enum, values: [:succeeded, :failed]
    field :failure_category, Ecto.Enum, values: @failure_categories
    field :provider_request_id, :string
    field :attempts, :integer
    field :validated_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :provider_credential, ProviderCredential
    belongs_to :validated_by_user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def success_changeset(
        validation,
        %ProviderCredential{} = credential,
        %User{} = user,
        %CredentialValidation{} = result,
        at
      ) do
    validation
    |> change(
      requested_model: result.requested_model,
      returned_model: result.returned_model,
      status: :succeeded,
      failure_category: nil,
      provider_request_id: result.request_id,
      attempts: result.attempts,
      validated_at: at,
      workspace_id: credential.workspace_id,
      provider_credential_id: credential.id,
      validated_by_user_id: user.id
    )
    |> validate_result()
  end

  def failure_changeset(
        validation,
        %ProviderCredential{} = credential,
        %User{} = user,
        %Failure{} = failure,
        at
      ) do
    validation
    |> change(
      requested_model: failure.requested_model,
      returned_model: failure.returned_model,
      status: :failed,
      failure_category: failure.category,
      provider_request_id: failure.request_id,
      attempts: failure.attempts,
      validated_at: at,
      workspace_id: credential.workspace_id,
      provider_credential_id: credential.id,
      validated_by_user_id: user.id
    )
    |> validate_result()
  end

  defp validate_result(changeset) do
    changeset
    |> validate_required([
      :requested_model,
      :status,
      :attempts,
      :validated_at,
      :workspace_id,
      :provider_credential_id,
      :validated_by_user_id
    ])
    |> validate_length(:requested_model, min: 1, max: 200)
    |> validate_length(:returned_model, max: 200)
    |> validate_length(:provider_request_id, max: 200)
    |> validate_number(:attempts, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:provider_credential_id)
    |> foreign_key_constraint(:validated_by_user_id)
    |> unique_constraint([:provider_credential_id, :requested_model],
      name: :provider_credential_model_validations_credential_model_index
    )
    |> check_constraint(:status, name: :provider_credential_model_validations_status_check)
    |> check_constraint(:failure_category,
      name: :provider_credential_model_validations_failure_category_check
    )
    |> check_constraint(:attempts, name: :provider_credential_model_validations_attempts_check)
    |> check_constraint(:status, name: :provider_credential_model_validations_result_check)
  end
end
