defmodule SilentRegression.Workspaces.Workspace do
  @moduledoc """
  The tenant and private-alpha entitlement boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:active, :suspended, :closed]

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :timezone, :string, default: "Etc/UTC"
    field :alpha_access, :boolean, default: true
    field :closed_at, :utc_datetime
    field :deletion_requested_at, :utc_datetime
    field :purge_after, :utc_datetime

    has_many :memberships, SilentRegression.Workspaces.Membership
    has_many :invitations, SilentRegression.Workspaces.Invitation
    belongs_to :closed_by_user, SilentRegression.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :timezone])
    |> update_change(:name, &String.trim/1)
    |> update_change(:slug, &(String.trim(&1) |> String.downcase()))
    |> update_change(:timezone, &String.trim/1)
    |> validate_required([:name, :slug, :timezone])
    |> validate_length(:name, max: 160)
    |> validate_length(:slug, min: 2, max: 80)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must use lowercase letters, numbers, and single hyphens"
    )
    |> validate_length(:timezone, max: 80)
    |> unique_constraint(:slug)
    |> check_constraint(:status, name: :workspaces_status_check)
  end

  def statuses, do: @statuses

  def close_changeset(workspace, user, mode, at, purge_after)
      when mode in [:closure_retention, :explicit_request] do
    deletion_requested_at = if mode == :explicit_request, do: at

    workspace
    |> change(
      status: :closed,
      closed_at: at,
      deletion_requested_at: deletion_requested_at,
      purge_after: purge_after,
      closed_by_user_id: user.id
    )
    |> check_constraint(:status, name: :workspaces_status_check)
    |> check_constraint(:status, name: :workspaces_retention_lifecycle_check)
    |> foreign_key_constraint(:closed_by_user_id)
  end

  def reopen_changeset(workspace) do
    workspace
    |> change(
      status: :active,
      closed_at: nil,
      deletion_requested_at: nil,
      purge_after: nil,
      closed_by_user_id: nil
    )
    |> check_constraint(:status, name: :workspaces_status_check)
    |> check_constraint(:status, name: :workspaces_retention_lifecycle_check)
  end
end
