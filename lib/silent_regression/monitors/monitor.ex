defmodule SilentRegression.Monitors.Monitor do
  @moduledoc """
  Stable workspace-scoped monitor identity and operational lifecycle.

  Name and description are metadata-only. Executable behavior belongs to
  immutable monitor versions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Monitors.MonitorVersion
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [:draft, :validating, :ready, :baseline_pending, :active, :paused, :archived]
  @cadences [:manual, :daily, :weekly]
  @capacity_wait_reasons [:workspace_run_limit, :workspace_call_limit]

  @pause_reasons [
    :owner_paused,
    :credential_unavailable,
    :incompatible_configuration,
    :repeated_authentication_failures,
    :workspace_call_limit,
    :workspace_run_limit,
    :per_run_call_limit,
    :workspace_closed,
    :schedule_owner_unavailable
  ]

  schema "monitors" do
    field :name, :string
    field :description, :string, default: ""
    field :state, Ecto.Enum, values: @states, default: :draft
    field :state_changed_at, :utc_datetime
    field :archived_at, :utc_datetime
    field :cadence, Ecto.Enum, values: @cadences, default: :manual
    field :next_run_at, :utc_datetime
    field :last_scheduled_at, :utc_datetime
    field :schedule_updated_at, :utc_datetime
    field :pause_reason, Ecto.Enum, values: @pause_reasons
    field :capacity_wait_reason, Ecto.Enum, values: @capacity_wait_reasons
    field :capacity_retry_at, :utc_datetime
    field :capacity_intended_at, :utc_datetime
    field :coverage_interrupted_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :created_by_user, User
    belongs_to :schedule_updated_by_user, User
    belongs_to :active_version, MonitorVersion
    belongs_to :draft_version, MonitorVersion
    belongs_to :provider_credential, ProviderCredential
    has_many :versions, MonitorVersion
    has_many :contract_versions, ContractVersion

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

  def credential_changeset(
        %__MODULE__{workspace_id: workspace_id} = monitor,
        %ProviderCredential{workspace_id: workspace_id} = credential
      ) do
    monitor
    |> change(provider_credential_id: credential.id)
    |> foreign_key_constraint(:provider_credential_id)
  end

  def credential_changeset(%__MODULE__{} = monitor, %ProviderCredential{}) do
    monitor
    |> change()
    |> add_error(:provider_credential_id, "does not belong to this workspace")
  end

  def credential_replacement_changeset(
        %__MODULE__{workspace_id: workspace_id} = monitor,
        %ProviderCredential{workspace_id: workspace_id} = credential,
        at
      ) do
    attrs =
      if monitor.state == :active do
        %{
          provider_credential_id: credential.id,
          state: :paused,
          state_changed_at: at,
          next_run_at: nil,
          pause_reason: :incompatible_configuration,
          capacity_wait_reason: nil,
          capacity_retry_at: nil,
          capacity_intended_at: nil,
          coverage_interrupted_at: nil
        }
      else
        %{provider_credential_id: credential.id}
      end

    monitor
    |> change(attrs)
    |> validate_schedule()
    |> add_constraints()
  end

  def credential_replacement_changeset(%__MODULE__{} = monitor, %ProviderCredential{}, _at) do
    monitor
    |> change()
    |> add_error(:provider_credential_id, "does not belong to this workspace")
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
        archived_at: nil,
        capacity_wait_reason: nil,
        capacity_retry_at: nil,
        capacity_intended_at: nil,
        coverage_interrupted_at: nil
      )
      |> add_constraints()
    end
  end

  def transition_changeset(%__MODULE__{} = monitor, target, at) when target in @states do
    if transition_allowed?(monitor.state, target) do
      archived_at = if target == :archived, do: at, else: nil

      capacity_attrs =
        if target == :archived do
          %{
            next_run_at: nil,
            pause_reason: nil,
            capacity_wait_reason: nil,
            capacity_retry_at: nil,
            capacity_intended_at: nil,
            coverage_interrupted_at: nil
          }
        else
          %{}
        end

      changeset =
        monitor
        |> change(
          Map.merge(capacity_attrs, %{
            state: target,
            state_changed_at: at,
            archived_at: archived_at
          })
        )

      changeset
      |> then(fn changeset ->
        if target == :archived, do: validate_schedule(changeset), else: changeset
      end)
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

  def replacement_baseline_changeset(
        %__MODULE__{state: state} = monitor,
        at
      )
      when state in [:active, :paused] do
    monitor
    |> change(
      state: :baseline_pending,
      state_changed_at: at,
      next_run_at: nil,
      pause_reason: nil,
      capacity_wait_reason: nil,
      capacity_retry_at: nil,
      capacity_intended_at: nil,
      coverage_interrupted_at: nil
    )
    |> validate_schedule()
    |> add_constraints()
  end

  def replacement_baseline_changeset(%__MODULE__{} = monitor, _at) do
    monitor
    |> change()
    |> add_error(:state, "cannot prepare a replacement baseline from #{monitor.state}")
  end

  def successor_activation_changeset(
        %__MODULE__{state: state} = monitor,
        %MonitorVersion{status: version_status} = version,
        %ProviderCredential{} = credential,
        at
      )
      when state in [:active, :paused] and version_status in [:draft, :active] do
    monitor
    |> change(
      active_version_id: version.id,
      draft_version_id: nil,
      provider_credential_id: credential.id,
      state: :baseline_pending,
      state_changed_at: at,
      cadence: :manual,
      next_run_at: nil,
      last_scheduled_at: nil,
      schedule_updated_at: nil,
      schedule_updated_by_user_id: nil,
      pause_reason: nil,
      capacity_wait_reason: nil,
      capacity_retry_at: nil,
      capacity_intended_at: nil,
      coverage_interrupted_at: nil
    )
    |> validate_schedule()
    |> add_constraints()
  end

  def successor_activation_changeset(
        %__MODULE__{} = monitor,
        %MonitorVersion{},
        %ProviderCredential{},
        _at
      ) do
    monitor
    |> change()
    |> add_error(:state, "requires an active or paused monitor")
  end

  def schedule_changeset(
        %__MODULE__{} = monitor,
        %User{} = user,
        attrs
      ) do
    monitor
    |> cast(attrs, [
      :state,
      :state_changed_at,
      :cadence,
      :next_run_at,
      :last_scheduled_at,
      :pause_reason,
      :capacity_wait_reason,
      :capacity_retry_at,
      :capacity_intended_at,
      :coverage_interrupted_at
    ])
    |> put_change(:schedule_updated_by_user_id, user.id)
    |> put_change(:schedule_updated_at, Map.fetch!(attrs, :schedule_updated_at))
    |> validate_required([:cadence, :schedule_updated_at, :schedule_updated_by_user_id])
    |> validate_schedule()
    |> add_constraints()
  end

  def system_schedule_changeset(%__MODULE__{} = monitor, attrs) do
    monitor
    |> cast(attrs, [
      :state,
      :state_changed_at,
      :next_run_at,
      :last_scheduled_at,
      :pause_reason,
      :capacity_wait_reason,
      :capacity_retry_at,
      :capacity_intended_at,
      :coverage_interrupted_at
    ])
    |> validate_schedule()
    |> add_constraints()
  end

  def states, do: @states
  def cadences, do: @cadences
  def pause_reasons, do: @pause_reasons
  def capacity_wait_reasons, do: @capacity_wait_reasons

  def capacity_wait_changeset(
        %__MODULE__{state: :active, cadence: cadence} = monitor,
        reason,
        intended_at,
        retry_at,
        interrupted_at
      )
      when cadence in [:daily, :weekly] and reason in @capacity_wait_reasons do
    monitor
    |> change(
      next_run_at: retry_at,
      capacity_wait_reason: reason,
      capacity_retry_at: retry_at,
      capacity_intended_at: intended_at,
      coverage_interrupted_at: monitor.coverage_interrupted_at || interrupted_at
    )
    |> validate_schedule()
    |> add_constraints()
  end

  def capacity_wait_changeset(%__MODULE__{} = monitor, _reason, _intended_at, _retry_at, _at) do
    monitor
    |> change()
    |> add_error(:capacity_wait_reason, "requires an active automatic schedule")
  end

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

  defp validate_schedule(changeset) do
    cadence = get_field(changeset, :cadence)
    state = get_field(changeset, :state)
    next_run_at = get_field(changeset, :next_run_at)
    pause_reason = get_field(changeset, :pause_reason)
    capacity_wait_reason = get_field(changeset, :capacity_wait_reason)
    capacity_retry_at = get_field(changeset, :capacity_retry_at)
    capacity_intended_at = get_field(changeset, :capacity_intended_at)
    coverage_interrupted_at = get_field(changeset, :coverage_interrupted_at)

    changeset
    |> then(fn changeset ->
      if cadence == :manual and next_run_at do
        add_error(changeset, :next_run_at, "must be empty for a manual cadence")
      else
        changeset
      end
    end)
    |> then(fn changeset ->
      if state == :paused and next_run_at do
        add_error(changeset, :next_run_at, "must be empty while paused")
      else
        changeset
      end
    end)
    |> then(fn changeset ->
      if state == :active and cadence in [:daily, :weekly] and is_nil(next_run_at) do
        add_error(changeset, :next_run_at, "is required for an active schedule")
      else
        changeset
      end
    end)
    |> then(fn changeset ->
      cond do
        state == :paused and is_nil(pause_reason) ->
          add_error(changeset, :pause_reason, "is required while paused")

        state != :paused and not is_nil(pause_reason) ->
          add_error(changeset, :pause_reason, "must be empty unless paused")

        true ->
          changeset
      end
    end)
    |> then(fn changeset ->
      wait_fields = [capacity_retry_at, capacity_intended_at, coverage_interrupted_at]

      cond do
        is_nil(capacity_wait_reason) and Enum.any?(wait_fields, &(not is_nil(&1))) ->
          add_error(changeset, :capacity_wait_reason, "is required for capacity wait metadata")

        not is_nil(capacity_wait_reason) and Enum.any?(wait_fields, &is_nil/1) ->
          add_error(changeset, :capacity_wait_reason, "requires complete capacity wait metadata")

        not is_nil(capacity_wait_reason) and
            (state != :active or cadence not in [:daily, :weekly] or
               next_run_at != capacity_retry_at or not is_nil(pause_reason)) ->
          add_error(changeset, :capacity_wait_reason, "does not match the active retry schedule")

        true ->
          changeset
      end
    end)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:active_version_id)
    |> foreign_key_constraint(:schedule_updated_by_user_id)
    |> check_constraint(:state, name: :monitors_state_check)
    |> check_constraint(:archived_at, name: :monitors_archived_at_check)
    |> check_constraint(:cadence, name: :monitors_cadence_check)
    |> check_constraint(:pause_reason, name: :monitors_pause_reason_check)
    |> check_constraint(:next_run_at, name: :monitors_manual_schedule_check)
    |> check_constraint(:next_run_at, name: :monitors_paused_schedule_check)
    |> check_constraint(:capacity_wait_reason, name: :monitors_capacity_wait_check)
  end
end
