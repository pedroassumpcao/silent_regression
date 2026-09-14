defmodule SilentRegression.Audit.AuditEvent do
  @moduledoc """
  Append-only, content-free security and lifecycle evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_events" do
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :workspace, SilentRegression.Workspaces.Workspace
    belongs_to :actor_user, SilentRegression.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def record_changeset(event, attrs) do
    event
    |> change(
      action: attrs[:action],
      target_type: attrs[:target_type],
      target_id: attrs[:target_id],
      metadata: attrs[:metadata] || %{},
      occurred_at: attrs[:occurred_at] || DateTime.utc_now(:second),
      workspace_id: attrs[:workspace_id],
      actor_user_id: attrs[:actor_user_id]
    )
    |> validate_required([:action, :target_type, :occurred_at])
    |> validate_length(:action, max: 160)
    |> validate_length(:target_type, max: 80)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:actor_user_id)
  end
end
