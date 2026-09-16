defmodule SilentRegression.Captures.CaptureRun do
  @moduledoc """
  Immutable capture plan with a small durable lifecycle.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.Captures.CaptureObservation
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:baseline, :manual, :scheduled]
  @statuses [
    :planned,
    :queued,
    :running,
    :succeeded,
    :partial_failed,
    :failed,
    :cancelled,
    :needs_review
  ]
  @providers [:openai, :anthropic]

  schema "capture_runs" do
    field :identity_key, :string
    field :kind, Ecto.Enum, values: @kinds
    field :status, Ecto.Enum, values: @statuses, default: :planned
    field :provider, Ecto.Enum, values: @providers
    field :requested_model, :string
    field :monitor_fingerprint, :string
    field :case_set_fingerprint, :string
    field :contract_fingerprint, :string
    field :evaluator_engine_version, :string
    field :samples_per_case, :integer
    field :retry_limit, :integer
    field :planned_call_count, :integer
    field :maximum_call_count, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :cancellation_requested_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :monitor_version, MonitorVersion
    belongs_to :contract_version, ContractVersion
    belongs_to :provider_credential, ProviderCredential
    belongs_to :baseline_snapshot, BaselineSnapshot
    belongs_to :created_by_user, User
    has_many :observations, CaptureObservation

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @plan_fields [
    :identity_key,
    :kind,
    :provider,
    :requested_model,
    :monitor_fingerprint,
    :case_set_fingerprint,
    :contract_fingerprint,
    :evaluator_engine_version,
    :samples_per_case,
    :retry_limit,
    :planned_call_count,
    :maximum_call_count
  ]

  def create_changeset(run, associations, attrs) do
    run
    |> cast(attrs, @plan_fields)
    |> put_change(:status, :planned)
    |> put_change(:workspace_id, associations.workspace_id)
    |> put_change(:monitor_id, associations.monitor_id)
    |> put_change(:monitor_version_id, associations.monitor_version_id)
    |> put_change(:contract_version_id, associations.contract_version_id)
    |> put_change(:provider_credential_id, associations.provider_credential_id)
    |> put_change(:baseline_snapshot_id, Map.get(associations, :baseline_snapshot_id))
    |> put_change(:created_by_user_id, associations.created_by_user_id)
    |> validate_required(
      @plan_fields ++
        [
          :status,
          :workspace_id,
          :monitor_id,
          :monitor_version_id,
          :contract_version_id,
          :provider_credential_id,
          :created_by_user_id
        ]
    )
    |> validate_length(:identity_key, min: 1, max: 200)
    |> validate_length(:requested_model, min: 1, max: 200)
    |> validate_length(:evaluator_engine_version, min: 1, max: 100)
    |> validate_number(:samples_per_case, greater_than: 0)
    |> validate_number(:retry_limit, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_number(:planned_call_count, greater_than: 0)
    |> validate_number(:maximum_call_count, greater_than: 0)
    |> validate_fingerprints()
    |> add_constraints()
  end

  def lifecycle_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :started_at, :completed_at, :cancellation_requested_at])
    |> validate_required(:status)
    |> add_constraints()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  defp validate_fingerprints(changeset) do
    Enum.reduce(
      [:monitor_fingerprint, :case_set_fingerprint, :contract_fingerprint],
      changeset,
      &validate_format(&2, &1, ~r/^[0-9a-f]{64}$/)
    )
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:monitor_version_id)
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:provider_credential_id)
    |> foreign_key_constraint(:baseline_snapshot_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:workspace_id, :identity_key])
    |> check_constraint(:kind, name: :capture_runs_kind_check)
    |> check_constraint(:status, name: :capture_runs_status_check)
    |> check_constraint(:provider, name: :capture_runs_provider_check)
    |> check_constraint(:maximum_call_count, name: :capture_runs_counts_check)
    |> check_constraint(:contract_fingerprint, name: :capture_runs_fingerprints_check)
    |> check_constraint(:status, name: :capture_runs_lifecycle_check)
  end
end
