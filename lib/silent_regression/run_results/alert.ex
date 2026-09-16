defmodule SilentRegression.RunResults.Alert do
  @moduledoc """
  Durable, explainable action item derived from one immutable capture run.

  Finding identity and evidence are immutable. The small forward-only lifecycle is intentionally
  separate from the append-only human review decisions introduced in Task 13.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Captures.{CaptureEvaluation, CaptureRun}
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories [:contract_failure, :operational_anomaly]
  @severities [:critical, :warning]
  @statuses [:open, :acknowledged, :resolved]
  @notification_states [:not_configured, :pending, :sent, :failed]

  schema "result_alerts" do
    field :identity_key, :string
    field :category, Ecto.Enum, values: @categories
    field :severity, Ecto.Enum, values: @severities
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :code, :string
    field :title, :string
    field :explanation, :string
    field :evidence, :map, default: %{}

    field :notification_state,
          Ecto.Enum,
          values: @notification_states,
          default: :not_configured

    field :opened_at, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :capture_run, CaptureRun
    belongs_to :capture_evaluation, CaptureEvaluation
    belongs_to :acknowledged_by_user, User
    belongs_to :resolved_by_user, User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(alert, associations, attrs) do
    alert
    |> cast(attrs, [
      :identity_key,
      :category,
      :severity,
      :code,
      :title,
      :explanation,
      :evidence,
      :opened_at
    ])
    |> put_change(:status, :open)
    |> put_change(:notification_state, :not_configured)
    |> put_change(:workspace_id, associations.workspace_id)
    |> put_change(:monitor_id, associations.monitor_id)
    |> put_change(:capture_run_id, associations.capture_run_id)
    |> put_change(:capture_evaluation_id, Map.get(associations, :capture_evaluation_id))
    |> validate_required([
      :identity_key,
      :category,
      :severity,
      :status,
      :code,
      :title,
      :explanation,
      :evidence,
      :notification_state,
      :opened_at,
      :workspace_id,
      :monitor_id,
      :capture_run_id
    ])
    |> validate_length(:identity_key, min: 1, max: 200)
    |> validate_length(:code, min: 1, max: 100)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:explanation, min: 1, max: 1_000)
    |> add_constraints()
  end

  def acknowledge_changeset(%__MODULE__{status: :open} = alert, %User{} = user, at) do
    alert
    |> change(status: :acknowledged, acknowledged_by_user_id: user.id, acknowledged_at: at)
    |> validate_required([:acknowledged_by_user_id, :acknowledged_at])
    |> add_constraints()
  end

  def acknowledge_changeset(%__MODULE__{} = alert, _user, _at), do: change(alert)

  def resolve_changeset(%__MODULE__{status: :acknowledged} = alert, %User{} = user, at) do
    alert
    |> change(status: :resolved, resolved_by_user_id: user.id, resolved_at: at)
    |> validate_required([:resolved_by_user_id, :resolved_at])
    |> add_constraints()
  end

  def resolve_changeset(%__MODULE__{} = alert, _user, _at) do
    alert
    |> change()
    |> add_error(:status, "must be acknowledged before it can be resolved")
  end

  def categories, do: @categories
  def severities, do: @severities
  def statuses, do: @statuses

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:capture_evaluation_id)
    |> foreign_key_constraint(:acknowledged_by_user_id)
    |> foreign_key_constraint(:resolved_by_user_id)
    |> unique_constraint([:workspace_id, :identity_key])
    |> check_constraint(:category, name: :result_alerts_category_check)
    |> check_constraint(:severity, name: :result_alerts_severity_check)
    |> check_constraint(:status, name: :result_alerts_status_check)
    |> check_constraint(:notification_state, name: :result_alerts_notification_state_check)
    |> check_constraint(:status, name: :result_alerts_lifecycle_check)
  end
end
