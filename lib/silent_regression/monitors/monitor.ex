defmodule SilentRegression.Monitors.Monitor do
  @moduledoc """
  Stable workspace-scoped monitor identity and operational lifecycle.

  Name and description are metadata-only. Executable behavior belongs to
  immutable monitor versions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Monitors.MonitorVersion
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [:draft, :validating, :ready, :baseline_pending, :active, :paused, :archived]

  schema "monitors" do
    field :name, :string
    field :description, :string, default: ""
    field :state, Ecto.Enum, values: @states, default: :draft
    field :state_changed_at, :utc_datetime
    field :archived_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :created_by_user, User
    belongs_to :active_version, MonitorVersion
    belongs_to :draft_version, MonitorVersion
    has_many :versions, MonitorVersion

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(monitor, %Workspace{} = workspace, %User{} = user, attrs) do
    now = DateTime.utc_now(:second)

    monitor
    |> cast(attrs, [:name, :description])
    |> put_change(:workspace_id, workspace.id)
    |> put_change(:created_by_user_id, user.id)
    |> put_change(:state, :draft)
    |> put_change(:state_changed_at, now)
    |> validate_metadata()
    |> add_constraints()
  end

  def metadata_changeset(monitor, attrs) do
    monitor
    |> cast(attrs, [:name, :description])
    |> validate_metadata()
  end

  def candidate_changeset(monitor, %MonitorVersion{} = version) do
    monitor
    |> change(draft_version_id: version.id)
    |> foreign_key_constraint(:draft_version_id)
  end

  def activate_configuration_changeset(
        %__MODULE__{state: state} = monitor,
        %MonitorVersion{} = version,
        at
      ) do
    if state == :archived do
      monitor
      |> change()
      |> add_error(:state, "archived monitors cannot activate a configuration")
    else
      monitor
      |> change(
        active_version_id: version.id,
        draft_version_id: nil,
        state: :validating,
        state_changed_at: at,
        archived_at: nil
      )
      |> add_constraints()
    end
  end

  def transition_changeset(%__MODULE__{} = monitor, target, at) when target in @states do
    if transition_allowed?(monitor.state, target) do
      archived_at = if target == :archived, do: at, else: nil

      monitor
      |> change(state: target, state_changed_at: at, archived_at: archived_at)
      |> add_constraints()
    else
      monitor
      |> change()
      |> add_error(:state, "cannot transition from #{monitor.state} to #{target}")
    end
  end

  def transition_changeset(%__MODULE__{} = monitor, _target, _at) do
    monitor
    |> change()
    |> add_error(:state, "has an invalid target")
  end

  def states, do: @states

  def transition_allowed?(:validating, target) when target in [:draft, :ready], do: true

  def transition_allowed?(:ready, target) when target in [:validating, :baseline_pending],
    do: true

  def transition_allowed?(:baseline_pending, target) when target in [:ready, :active], do: true
  def transition_allowed?(:active, :paused), do: true
  def transition_allowed?(:paused, :active), do: true
  def transition_allowed?(state, :archived) when state != :archived, do: true
  def transition_allowed?(_state, _target), do: false

  defp validate_metadata(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> validate_required([:name, :state, :state_changed_at, :workspace_id])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:description, max: 2_000)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:active_version_id)
    |> check_constraint(:state, name: :monitors_state_check)
    |> check_constraint(:archived_at, name: :monitors_archived_at_check)
  end
end
