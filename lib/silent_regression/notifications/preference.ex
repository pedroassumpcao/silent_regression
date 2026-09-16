defmodule SilentRegression.Notifications.Preference do
  @moduledoc """
  Stores one member's workspace-scoped actionable-alert email preference.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "notification_preferences" do
    field :actionable_alert_email_enabled, :boolean, default: true

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preference, associations, attrs) do
    preference
    |> cast(attrs, [:actionable_alert_email_enabled])
    |> put_change(:workspace_id, associations.workspace_id)
    |> put_change(:user_id, associations.user_id)
    |> validate_required([:actionable_alert_email_enabled, :workspace_id, :user_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id])
  end
end
