defmodule SilentRegression.Workspaces.Invitation do
  @moduledoc """
  A single-use, expiring authorization to join one workspace.

  Only the SHA-256 token hash is persisted. The encoded bearer token is returned
  once to the operator or inviter and cannot be reconstructed from this record.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles [:owner, :member]
  @statuses [:pending, :accepted, :revoked, :expired]

  schema "workspace_invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: @roles
    field :token_hash, :binary, redact: true
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :invited_by_user, User
    belongs_to :accepted_by_user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(
        invitation,
        %Workspace{} = workspace,
        inviter,
        attrs,
        token_hash,
        expires_at
      ) do
    invitation
    |> cast(attrs, [:email, :role])
    |> update_change(:email, &(String.trim(&1) |> String.downcase()))
    |> put_change(:workspace_id, workspace.id)
    |> put_change(:invited_by_user_id, user_id(inviter))
    |> put_change(:token_hash, token_hash)
    |> put_change(:expires_at, expires_at)
    |> put_change(:status, :pending)
    |> validate_required([:email, :role, :workspace_id, :token_hash, :expires_at, :status])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:invited_by_user_id)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:email,
      name: :workspace_invitations_pending_email_index,
      message: "already has a pending invitation to this workspace"
    )
    |> check_constraint(:role, name: :workspace_invitations_role_check)
    |> check_constraint(:status, name: :workspace_invitations_status_check)
  end

  def accept_changeset(invitation, %User{} = user, accepted_at) do
    invitation
    |> change(status: :accepted, accepted_by_user_id: user.id, accepted_at: accepted_at)
    |> foreign_key_constraint(:accepted_by_user_id)
    |> check_constraint(:status, name: :workspace_invitations_status_check)
  end

  def revoke_changeset(invitation, revoked_at) do
    invitation
    |> change(status: :revoked, revoked_at: revoked_at)
    |> check_constraint(:status, name: :workspace_invitations_status_check)
  end

  def expire_changeset(invitation) do
    invitation
    |> change(status: :expired)
    |> check_constraint(:status, name: :workspace_invitations_status_check)
  end

  def state(%__MODULE__{status: :pending, expires_at: expires_at}, now) do
    if DateTime.after?(expires_at, now), do: :pending, else: :expired
  end

  def state(%__MODULE__{status: status}, _now), do: status

  def roles, do: @roles
  def statuses, do: @statuses

  defp user_id(%User{id: id}), do: id
  defp user_id(nil), do: nil
end
