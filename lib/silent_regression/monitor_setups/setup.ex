defmodule SilentRegression.MonitorSetups.Setup do
  @moduledoc """
  Mutable intermediate state for the cold-start monitor flow.

  A setup is never executable. Completion promotes its normalized content into
  an immutable `MonitorVersion` snapshot.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "monitor_setups" do
    field :status, Ecto.Enum, values: [:in_progress, :completed], default: :in_progress
    field :provider, Ecto.Enum, values: [:openai, :anthropic]
    field :requested_model, :string
    field :system_prompt, :string, default: ""
    field :user_prompt_template, :string, default: ""
    field :response_format, :map, default: %{"type" => "text"}
    field :generation_config, :map, default: %{"max_output_tokens" => 512}
    field :cases, :map, default: %{"items" => []}
    field :completed_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :provider_credential, ProviderCredential
    belongs_to :completed_monitor_version, MonitorVersion
    belongs_to :created_by_user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(setup, %Workspace{} = workspace, %Monitor{} = monitor, %User{} = user) do
    setup
    |> change(
      status: :in_progress,
      workspace_id: workspace.id,
      monitor_id: monitor.id,
      created_by_user_id: user.id
    )
    |> validate_required([:status, :workspace_id, :monitor_id, :created_by_user_id])
    |> add_constraints()
  end

  def connection_changeset(
        setup,
        %ProviderCredential{} = credential,
        provider,
        requested_model
      ) do
    setup
    |> change(
      provider_credential_id: credential.id,
      provider: provider,
      requested_model: requested_model
    )
    |> validate_required([:provider_credential_id, :provider, :requested_model])
    |> validate_length(:requested_model, min: 1, max: 200)
    |> add_constraints()
  end

  def prompt_changeset(setup, attrs) do
    setup
    |> change(attrs)
    |> validate_required([
      :user_prompt_template,
      :response_format,
      :generation_config
    ])
    |> add_constraints()
  end

  def cases_changeset(setup, cases) when is_list(cases) do
    setup
    |> change(cases: %{"items" => cases})
    |> add_constraints()
  end

  def complete_changeset(setup, %MonitorVersion{} = version, at) do
    setup
    |> change(
      status: :completed,
      completed_at: at,
      completed_monitor_version_id: version.id
    )
    |> validate_required([:completed_at, :completed_monitor_version_id])
    |> add_constraints()
  end

  def error_changeset(setup, field, message) do
    setup
    |> change()
    |> add_error(field, message)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:provider_credential_id)
    |> foreign_key_constraint(:completed_monitor_version_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint(:monitor_id)
    |> check_constraint(:status, name: :monitor_setups_status_check)
    |> check_constraint(:provider, name: :monitor_setups_provider_check)
    |> check_constraint(:status, name: :monitor_setups_completion_check)
  end
end
