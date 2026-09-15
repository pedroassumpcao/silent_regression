defmodule SilentRegression.ProductAnalytics.ProductEvent do
  @moduledoc """
  Append-only, content-free evidence about private-alpha product usage.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "product_events" do
    field :name, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :properties, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :actor_user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def record_changeset(event, attrs) do
    event
    |> change(
      name: attrs.name,
      target_type: attrs.target_type,
      target_id: attrs.target_id,
      properties: attrs.properties,
      occurred_at: attrs.occurred_at,
      workspace_id: attrs.workspace_id,
      actor_user_id: attrs.actor_user_id
    )
    |> validate_required([
      :name,
      :target_type,
      :properties,
      :occurred_at,
      :workspace_id,
      :actor_user_id
    ])
    |> validate_length(:name, max: 160)
    |> validate_length(:target_type, max: 80)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_user_id)
    |> check_constraint(:name, name: :product_events_name_check)
  end
end
