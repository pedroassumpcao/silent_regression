defmodule SilentRegression.Baselines.BaselineSnapshot do
  @moduledoc """
  Durable authorization and immutable approval provenance for one baseline capture.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Baselines.BaselineMember
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :approved, :superseded, :rejected]
  @approval_modes [:normal, :exceptional]
  @providers [:openai, :anthropic]

  schema "baseline_snapshots" do
    field :authorization_key, Ecto.UUID
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :approval_mode, Ecto.Enum, values: @approval_modes
    field :approval_rationale, :string
    field :preview_fingerprint, :string
    field :provider, Ecto.Enum, values: @providers
    field :requested_model, :string
    field :monitor_fingerprint, :string
    field :case_set_fingerprint, :string
    field :contract_fingerprint, :string
    field :contract_semantics_fingerprint, :string
    field :evaluator_engine_version, :string
    field :samples_per_case, :integer
    field :retry_limit, :integer
    field :planned_call_count, :integer
    field :maximum_call_count, :integer
    field :authorized_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :monitor_version, MonitorVersion
    belongs_to :contract_version, ContractVersion
    belongs_to :provider_credential, ProviderCredential
    belongs_to :capture_run, CaptureRun
    belongs_to :authorized_by_user, User
    belongs_to :approved_by_user, User
    belongs_to :rejected_by_user, User
    belongs_to :superseded_by, __MODULE__
    has_many :members, BaselineMember

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @plan_fields [
    :authorization_key,
    :preview_fingerprint,
    :provider,
    :requested_model,
    :monitor_fingerprint,
    :case_set_fingerprint,
    :contract_fingerprint,
    :contract_semantics_fingerprint,
    :evaluator_engine_version,
    :samples_per_case,
    :retry_limit,
    :planned_call_count,
    :maximum_call_count,
    :authorized_at
  ]

  def create_changeset(snapshot, associations, attrs) do
    snapshot
    |> cast(attrs, @plan_fields)
    |> put_change(:status, :pending)
    |> put_change(:workspace_id, associations.workspace_id)
    |> put_change(:monitor_id, associations.monitor_id)
    |> put_change(:monitor_version_id, associations.monitor_version_id)
    |> put_change(:contract_version_id, associations.contract_version_id)
    |> put_change(:provider_credential_id, associations.provider_credential_id)
    |> put_change(:capture_run_id, associations.capture_run_id)
    |> put_change(:authorized_by_user_id, associations.authorized_by_user_id)
    |> validate_required(
      @plan_fields ++
        [
          :status,
          :workspace_id,
          :monitor_id,
          :monitor_version_id,
          :contract_version_id,
          :provider_credential_id,
          :capture_run_id,
          :authorized_by_user_id
        ]
    )
    |> validate_length(:requested_model, min: 1, max: 200)
    |> validate_length(:evaluator_engine_version, min: 1, max: 100)
    |> validate_number(:samples_per_case, greater_than: 0, less_than_or_equal_to: 5)
    |> validate_number(:retry_limit, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_number(:planned_call_count, greater_than: 0)
    |> validate_number(:maximum_call_count, greater_than: 0)
    |> validate_fingerprints()
    |> add_constraints()
  end

  def approve_changeset(snapshot, %User{} = user, mode, rationale, at) do
    rationale = normalize_rationale(rationale)

    snapshot
    |> change(
      status: :approved,
      approval_mode: mode,
      approval_rationale: rationale,
      approved_by_user_id: user.id,
      approved_at: at
    )
    |> validate_required([:status, :approval_mode, :approved_by_user_id, :approved_at])
    |> validate_exceptional_rationale()
    |> foreign_key_constraint(:approved_by_user_id)
    |> add_constraints()
  end

  def supersede_changeset(snapshot, %__MODULE__{} = replacement, at) do
    snapshot
    |> change(status: :superseded, superseded_by_id: replacement.id, superseded_at: at)
    |> validate_required([:status, :superseded_by_id, :superseded_at])
    |> foreign_key_constraint(:superseded_by_id)
    |> add_constraints()
  end

  def reject_changeset(snapshot, %User{} = user, at) do
    snapshot
    |> change(status: :rejected, rejected_by_user_id: user.id, rejected_at: at)
    |> validate_required([:status, :rejected_by_user_id, :rejected_at])
    |> foreign_key_constraint(:rejected_by_user_id)
    |> add_constraints()
  end

  def statuses, do: @statuses
  def approval_modes, do: @approval_modes

  defp normalize_rationale(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_rationale(_value), do: nil

  defp validate_exceptional_rationale(changeset) do
    case get_field(changeset, :approval_mode) do
      :exceptional ->
        changeset
        |> validate_required(:approval_rationale)
        |> validate_length(:approval_rationale, min: 20, max: 2_000)

      _mode ->
        put_change(changeset, :approval_rationale, nil)
    end
  end

  defp validate_fingerprints(changeset) do
    Enum.reduce(
      [
        :preview_fingerprint,
        :monitor_fingerprint,
        :case_set_fingerprint,
        :contract_fingerprint,
        :contract_semantics_fingerprint
      ],
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
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:authorized_by_user_id)
    |> unique_constraint(:authorization_key)
    |> unique_constraint(:capture_run_id)
    |> unique_constraint(:monitor_id, name: :baseline_snapshots_one_pending_index)
    |> unique_constraint(:monitor_id, name: :baseline_snapshots_one_approved_index)
    |> check_constraint(:status, name: :baseline_snapshots_status_check)
    |> check_constraint(:approval_mode, name: :baseline_snapshots_approval_mode_check)
    |> check_constraint(:provider, name: :baseline_snapshots_provider_check)
    |> check_constraint(:maximum_call_count, name: :baseline_snapshots_counts_check)
    |> check_constraint(:preview_fingerprint, name: :baseline_snapshots_fingerprints_check)
    |> check_constraint(:contract_semantics_fingerprint,
      name: :baseline_snapshots_contract_semantics_fingerprint_check
    )
    |> check_constraint(:status, name: :baseline_snapshots_lifecycle_check)
  end
end
