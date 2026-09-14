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

    has_many :memberships, SilentRegression.Workspaces.Membership
    has_many :invitations, SilentRegression.Workspaces.Invitation

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
end
