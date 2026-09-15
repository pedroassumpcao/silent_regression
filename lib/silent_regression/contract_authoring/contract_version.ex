defmodule SilentRegression.ContractAuthoring.ContractVersion do
  @moduledoc """
  Workspace-scoped deterministic contract version with sealed approval provenance.

  Draft content may change while it is being validated. Approved and retired
  content is protected by the database and can only be succeeded by a new draft.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ContractAuthoring.ContractFixture
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :approved, :retired]
  @assistance_modes [:self_serve, :founder_assisted, :codex_assisted]
  @fingerprint_fields [:contract_fingerprint, :fixture_set_fingerprint, :fingerprint]

  schema "contract_versions" do
    field :version, :integer
    field :schema_version, :integer, default: 1
    field :evaluator_engine_version, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :template_key, :string
    field :template_usage, :map
    field :assistance_mode, Ecto.Enum, values: @assistance_modes, default: :self_serve
    field :root, :map
    field :contract_fingerprint, :string
    field :fixture_set_fingerprint, :string
    field :fingerprint, :string
    field :approved_at, :utc_datetime
    field :retired_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :monitor_version, MonitorVersion
    belongs_to :predecessor, __MODULE__
    belongs_to :created_by_user, User
    belongs_to :approved_by_user, User
    has_many :fixtures, ContractFixture

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(contract_version, associations, attrs) do
    contract_version
    |> change(Map.take(attrs, content_fields()))
    |> change(
      status: :draft,
      workspace_id: associations.workspace.id,
      monitor_id: associations.monitor.id,
      monitor_version_id: associations.monitor_version.id,
      predecessor_id: associations.predecessor_id,
      created_by_user_id: associations.user.id
    )
    |> validate_content()
    |> add_constraints()
  end

  def update_draft_changeset(%__MODULE__{status: :draft} = contract_version, attrs) do
    contract_version
    |> change(Map.take(attrs, content_fields()))
    |> validate_content()
    |> add_constraints()
  end

  def update_draft_changeset(%__MODULE__{} = contract_version, _attrs) do
    contract_version
    |> change()
    |> add_error(:status, "only a draft contract can be edited")
  end

  def approve_changeset(%__MODULE__{status: :draft} = contract_version, %User{} = user, at, attrs) do
    contract_version
    |> change(Map.take(attrs, @fingerprint_fields))
    |> change(status: :approved, approved_by_user_id: user.id, approved_at: at)
    |> validate_content()
    |> add_constraints()
  end

  def approve_changeset(%__MODULE__{} = contract_version, _user, _at, _attrs) do
    contract_version
    |> change()
    |> add_error(:status, "only a draft contract can be approved")
  end

  def retire_changeset(%__MODULE__{status: :approved} = contract_version, at) do
    contract_version
    |> change(status: :retired, retired_at: at)
    |> add_constraints()
  end

  def retire_changeset(%__MODULE__{} = contract_version, _at) do
    contract_version
    |> change()
    |> add_error(:status, "only an approved contract can be retired")
  end

  def statuses, do: @statuses
  def assistance_modes, do: @assistance_modes

  defp content_fields do
    [
      :version,
      :schema_version,
      :evaluator_engine_version,
      :template_key,
      :template_usage,
      :assistance_mode,
      :root,
      :contract_fingerprint,
      :fixture_set_fingerprint,
      :fingerprint
    ]
  end

  defp validate_content(changeset) do
    changeset
    |> validate_required(
      content_fields() ++
        [
          :status,
          :workspace_id,
          :monitor_id,
          :monitor_version_id,
          :created_by_user_id
        ]
    )
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:evaluator_engine_version, min: 1, max: 80)
    |> validate_length(:template_key, min: 1, max: 80)
    |> validate_fingerprints()
  end

  defp validate_fingerprints(changeset) do
    Enum.reduce(@fingerprint_fields, changeset, fn field, changeset ->
      validate_format(changeset, field, ~r/^[0-9a-f]{64}$/)
    end)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:monitor_version_id)
    |> foreign_key_constraint(:predecessor_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:approved_by_user_id)
    |> unique_constraint([:monitor_id, :version])
    |> unique_constraint(:monitor_id, name: :contract_versions_one_draft_index)
    |> unique_constraint(:monitor_id, name: :contract_versions_one_approved_index)
    |> check_constraint(:version, name: :contract_versions_version_check)
    |> check_constraint(:schema_version, name: :contract_versions_schema_version_check)
    |> check_constraint(:status, name: :contract_versions_status_check)
    |> check_constraint(:assistance_mode, name: :contract_versions_assistance_mode_check)
    |> check_constraint(:fingerprint, name: :contract_versions_fingerprints_check)
    |> check_constraint(:status, name: :contract_versions_lifecycle_check)
  end
end
