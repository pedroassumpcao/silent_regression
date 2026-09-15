defmodule SilentRegression.Monitors.MonitorVersion do
  @moduledoc """
  Immutable executable configuration snapshot for a monitor.

  Only lifecycle status and timestamps may change after insertion. PostgreSQL
  rejects updates to behavior-affecting content.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Monitors.{CaseVersion, Monitor}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :active, :superseded]
  @providers [:openai, :anthropic]

  schema "monitor_versions" do
    field :version, :integer
    field :schema_version, :integer
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :provider, Ecto.Enum, values: @providers
    field :requested_model, :string
    field :system_prompt, :string, default: ""
    field :user_prompt_template, :string
    field :response_format, :map
    field :generation_config, :map
    field :case_set_fingerprint, :string
    field :fingerprint, :string
    field :activated_at, :utc_datetime
    field :superseded_at, :utc_datetime

    belongs_to :monitor, Monitor
    belongs_to :predecessor, __MODULE__
    belongs_to :created_by_user, User
    has_many :cases, CaseVersion

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @content_fields [
    :version,
    :schema_version,
    :provider,
    :requested_model,
    :system_prompt,
    :user_prompt_template,
    :response_format,
    :generation_config,
    :case_set_fingerprint,
    :fingerprint
  ]

  def create_changeset(version, %Monitor{} = monitor, %User{} = user, attrs) do
    version
    |> cast(attrs, @content_fields)
    |> put_change(:monitor_id, monitor.id)
    |> put_change(:created_by_user_id, user.id)
    |> put_change(:predecessor_id, attrs[:predecessor_id])
    |> put_change(:status, :draft)
    |> validate_required(@content_fields ++ [:monitor_id, :created_by_user_id, :status])
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:requested_model, min: 1, max: 200)
    |> validate_length(:system_prompt, max: 40_000)
    |> validate_length(:user_prompt_template, min: 1, max: 40_000)
    |> validate_format(:case_set_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:fingerprint, ~r/^[0-9a-f]{64}$/)
    |> add_constraints()
  end

  def activate_changeset(%__MODULE__{status: :draft} = version, at) do
    version
    |> change(status: :active, activated_at: at)
    |> add_constraints()
  end

  def activate_changeset(%__MODULE__{} = version, _at) do
    version
    |> change()
    |> add_error(:status, "only a draft version can be activated")
  end

  def supersede_changeset(%__MODULE__{status: status} = version, at)
      when status in [:draft, :active] do
    version
    |> change(status: :superseded, superseded_at: at)
    |> add_constraints()
  end

  def supersede_changeset(%__MODULE__{} = version, _at) do
    version
    |> change()
    |> add_error(:status, "is already superseded")
  end

  def statuses, do: @statuses

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:predecessor_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:monitor_id, :version])
    |> unique_constraint(:monitor_id, name: :monitor_versions_one_draft_index)
    |> unique_constraint(:monitor_id, name: :monitor_versions_one_active_index)
    |> check_constraint(:version, name: :monitor_versions_version_check)
    |> check_constraint(:schema_version, name: :monitor_versions_schema_version_check)
    |> check_constraint(:status, name: :monitor_versions_status_check)
    |> check_constraint(:provider, name: :monitor_versions_provider_check)
    |> check_constraint(:fingerprint, name: :monitor_versions_fingerprint_check)
    |> check_constraint(:status, name: :monitor_versions_lifecycle_timestamps_check)
  end
end
