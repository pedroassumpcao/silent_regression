defmodule SilentRegression.ProviderCredentials.ProviderCredential do
  @moduledoc """
  Encrypted provider credential and its immutable lifecycle identity.

  Public context operations return safe metadata maps instead of this schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Encrypted.Binary, as: EncryptedBinary
  alias SilentRegression.Providers.{CredentialValidation, Failure}
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers [:openai, :anthropic]
  @statuses [:pending_validation, :valid, :invalid, :revoked, :superseded]

  schema "provider_credentials" do
    field :provider, Ecto.Enum, values: @providers
    field :label, :string
    field :secret, EncryptedBinary, source: :encrypted_secret, redact: true
    field :secret_suffix, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending_validation
    field :last_validation_status, Ecto.Enum, values: [:succeeded, :failed]

    field :last_failure_category, Ecto.Enum,
      values: [
        :authentication,
        :authorization,
        :rate_limited,
        :transport,
        :provider,
        :malformed_response,
        :model_mismatch
      ]

    field :last_validated_at, :utc_datetime
    field :last_requested_model, :string
    field :last_returned_model, :string
    field :last_provider_request_id, :string
    field :last_validation_attempts, :integer
    field :revoked_at, :utc_datetime
    field :superseded_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :created_by_user, User
    belongs_to :revoked_by_user, User
    belongs_to :supersedes, __MODULE__
    has_one :successor, __MODULE__, foreign_key: :supersedes_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(credential, %Workspace{} = workspace, %User{} = user, attrs) do
    credential
    |> cast(attrs, [:provider, :label, :secret])
    |> put_change(:workspace_id, workspace.id)
    |> put_change(:created_by_user_id, user.id)
    |> put_change(:status, :pending_validation)
    |> normalize_fields()
    |> validate_create_fields()
    |> put_secret_suffix()
    |> add_constraints()
  end

  def rotation_changeset(
        credential,
        %Workspace{} = workspace,
        %User{} = user,
        %__MODULE__{} = superseded,
        attrs
      ) do
    attrs = %{
      provider: superseded.provider,
      label: Map.get(attrs, :label) || Map.get(attrs, "label") || superseded.label,
      secret: Map.get(attrs, :secret) || Map.get(attrs, "secret")
    }

    credential
    |> create_changeset(workspace, user, attrs)
    |> put_change(:supersedes_id, superseded.id)
  end

  def supersede_changeset(credential, at) do
    credential
    |> change(status: :superseded, superseded_at: at)
    |> check_constraint(:status, name: :provider_credentials_status_check)
  end

  def revoke_changeset(credential, %User{} = user, at) do
    credential
    |> change(status: :revoked, revoked_at: at, revoked_by_user_id: user.id)
    |> foreign_key_constraint(:revoked_by_user_id)
    |> check_constraint(:status, name: :provider_credentials_status_check)
  end

  def validation_changeset(credential, %CredentialValidation{} = result, at) do
    credential
    |> change(
      status: :valid,
      last_validation_status: :succeeded,
      last_failure_category: nil,
      last_validated_at: at,
      last_requested_model: result.requested_model,
      last_returned_model: result.returned_model,
      last_provider_request_id: result.request_id,
      last_validation_attempts: result.attempts
    )
    |> validate_validation_fields()
  end

  def validation_changeset(credential, %Failure{} = failure, at) do
    credential
    |> change(
      status: status_after_failure(credential.status, failure.category),
      last_validation_status: :failed,
      last_failure_category: failure.category,
      last_validated_at: at,
      last_requested_model: failure.requested_model,
      last_returned_model: failure.returned_model,
      last_provider_request_id: failure.request_id,
      last_validation_attempts: failure.attempts
    )
    |> validate_validation_fields()
  end

  def providers, do: @providers
  def statuses, do: @statuses

  defp normalize_fields(changeset) do
    changeset
    |> update_change(:label, &String.trim/1)
    |> update_change(:secret, &String.trim/1)
  end

  defp validate_create_fields(changeset) do
    changeset
    |> validate_required([
      :provider,
      :label,
      :secret,
      :workspace_id,
      :created_by_user_id,
      :status
    ])
    |> validate_length(:label, min: 1, max: 80)
    |> validate_length(:secret, min: 8, max: 512)
  end

  defp put_secret_suffix(changeset) do
    case get_change(changeset, :secret) do
      secret when is_binary(secret) and byte_size(secret) >= 4 ->
        put_change(changeset, :secret_suffix, binary_part(secret, byte_size(secret) - 4, 4))

      _other ->
        changeset
    end
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint(:supersedes_id)
    |> check_constraint(:provider, name: :provider_credentials_provider_check)
    |> check_constraint(:status, name: :provider_credentials_status_check)
  end

  defp validate_validation_fields(changeset) do
    changeset
    |> validate_required([:last_validation_status, :last_validated_at, :last_validation_attempts])
    |> validate_length(:last_requested_model, max: 200)
    |> validate_length(:last_returned_model, max: 200)
    |> validate_length(:last_provider_request_id, max: 200)
    |> validate_number(:last_validation_attempts, greater_than: 0)
    |> check_constraint(:status, name: :provider_credentials_status_check)
    |> check_constraint(:last_validation_status,
      name: :provider_credentials_validation_status_check
    )
    |> check_constraint(:last_failure_category,
      name: :provider_credentials_failure_category_check
    )
    |> check_constraint(:last_validation_attempts,
      name: :provider_credentials_attempts_check
    )
  end

  defp status_after_failure(_current_status, category)
       when category in [:authentication, :authorization, :model_mismatch],
       do: :invalid

  defp status_after_failure(current_status, _category), do: current_status
end
