defmodule SilentRegression.Workspaces.Membership do
  @moduledoc """
  Connects a user to a workspace with the deliberately small alpha role set.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles [:owner, :member]

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: @roles

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(membership, %Workspace{} = workspace, %User{} = user, role) do
    membership
    |> change(workspace_id: workspace.id, user_id: user.id, role: role)
    |> validate_required([:workspace_id, :user_id, :role])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id])
    |> check_constraint(:role, name: :workspace_memberships_role_check)
  end

  def roles, do: @roles
end
