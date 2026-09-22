defmodule SilentRegression.GuidedSetups.Draft do
  @moduledoc "Bounded authoring data, never an executable monitor configuration."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "guided_setup_drafts" do
    field :schema_version, :integer, default: 1
    field :recipe, :string, default: "routing"
    field :recipe_version, :integer, default: 1
    field :revision, :integer, default: 1
    field :raw, :map
    field :reviews, :map, default: %{}
    field :sealed_at, :utc_datetime
    belongs_to :workspace, SilentRegression.Workspaces.Workspace
    belongs_to :created_by_user, SilentRegression.Accounts.User
    belongs_to :monitor, SilentRegression.Monitors.Monitor
    timestamps(type: :utc_datetime)
  end
end
