defmodule SilentRegression.RunResults.Incident do
  @moduledoc """
  Durable lifecycle for one stable failure signature and one recurrence episode.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.Reviews.ReviewDecision
  alias SilentRegression.RunResults.IncidentOccurrence
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:open, :acknowledged, :resolved, :recovered]
  @categories [:contract_failure, :case_expectation_failure, :operational_anomaly]
  @severities [:critical, :warning]

  schema "result_incidents" do
    field :signature, :string
    field :signature_schema_version, :string
    field :signature_components, :map, default: %{}
    field :episode, :integer
    field :category, Ecto.Enum, values: @categories
    field :severity, Ecto.Enum, values: @severities
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :code, :string
    field :title, :string
    field :explanation, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :occurrence_count, :integer, default: 1
    field :run_count, :integer, default: 1
    field :affected_case_count, :integer, default: 0
    field :acknowledged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :recovered_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :monitor_version, MonitorVersion
    belongs_to :reopened_from, __MODULE__
    belongs_to :acknowledged_by_user, User
    belongs_to :resolved_by_user, User
    belongs_to :resolution_review_decision, ReviewDecision
    belongs_to :recovery_capture_run, CaptureRun
    has_many :occurrences, IncidentOccurrence, foreign_key: :result_incident_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(incident, associations, attrs) do
    incident
    |> cast(attrs, [
      :signature,
      :signature_schema_version,
      :signature_components,
      :episode,
      :category,
      :severity,
      :code,
      :title,
      :explanation,
      :first_seen_at,
      :last_seen_at,
      :affected_case_count
    ])
    |> change(
      status: :open,
      occurrence_count: 1,
      run_count: 1,
      workspace_id: associations.workspace_id,
      monitor_id: associations.monitor_id,
      monitor_version_id: associations.monitor_version_id,
      reopened_from_id: Map.get(associations, :reopened_from_id)
    )
    |> validate_required([
      :signature,
      :signature_schema_version,
      :signature_components,
      :episode,
      :category,
      :severity,
      :status,
      :code,
      :title,
      :explanation,
      :first_seen_at,
      :last_seen_at,
      :occurrence_count,
      :run_count,
      :affected_case_count,
      :workspace_id,
      :monitor_id,
      :monitor_version_id
    ])
    |> validate_length(:signature, min: 1, max: 200)
    |> validate_length(:signature_schema_version, min: 1, max: 80)
    |> validate_length(:code, min: 1, max: 100)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:explanation, min: 1, max: 1_000)
    |> add_constraints()
  end

  def recurrence_changeset(incident, attrs) do
    incident
    |> cast(attrs, [:last_seen_at, :occurrence_count, :run_count, :affected_case_count])
    |> validate_required([:last_seen_at, :occurrence_count, :run_count, :affected_case_count])
    |> add_constraints()
  end

  def acknowledge_changeset(%__MODULE__{status: :open} = incident, user, at) do
    incident
    |> change(status: :acknowledged, acknowledged_by_user_id: user.id, acknowledged_at: at)
    |> add_constraints()
  end

  def acknowledge_changeset(%__MODULE__{} = incident, _user, _at), do: change(incident)

  def resolve_changeset(
        %__MODULE__{status: :acknowledged} = incident,
        user,
        review_decision,
        at
      ) do
    incident
    |> change(
      status: :resolved,
      resolved_by_user_id: user.id,
      resolved_at: at,
      resolution_review_decision_id: review_decision.id
    )
    |> add_constraints()
  end

  def resolve_changeset(%__MODULE__{} = incident, _user, _review_decision, _at) do
    incident |> change() |> add_error(:status, "must be acknowledged before it can be resolved")
  end

  def recover_changeset(%__MODULE__{status: status} = incident, run, at)
      when status in [:open, :acknowledged] do
    incident
    |> change(
      status: :recovered,
      recovered_at: at,
      recovery_capture_run_id: run.id
    )
    |> add_constraints()
  end

  def statuses, do: @statuses

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:monitor_version_id)
    |> foreign_key_constraint(:reopened_from_id)
    |> foreign_key_constraint(:acknowledged_by_user_id)
    |> foreign_key_constraint(:resolved_by_user_id)
    |> foreign_key_constraint(:resolution_review_decision_id)
    |> foreign_key_constraint(:recovery_capture_run_id)
    |> unique_constraint([:workspace_id, :signature, :episode])
    |> unique_constraint([:workspace_id, :signature],
      name: :result_incidents_one_active_signature_index
    )
    |> check_constraint(:category, name: :result_incidents_category_check)
    |> check_constraint(:severity, name: :result_incidents_severity_check)
    |> check_constraint(:status, name: :result_incidents_status_check)
    |> check_constraint(:occurrence_count, name: :result_incidents_counts_check)
    |> check_constraint(:signature, name: :result_incidents_signature_check)
    |> check_constraint(:status, name: :result_incidents_lifecycle_check)
  end
end
