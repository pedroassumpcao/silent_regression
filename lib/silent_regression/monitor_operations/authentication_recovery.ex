defmodule SilentRegression.MonitorOperations.AuthenticationRecovery do
  @moduledoc """
  Immutable owner-authorized authentication breaker recovery epoch.

  Probe lifecycle remains on the linked capture run. This record snapshots the exact credential
  validation and authorization boundary that permitted the one-call half-open probe.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.ProviderCredentials.{ModelValidation, ProviderCredential}
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "monitor_authentication_recoveries" do
    field :epoch, :integer
    field :requested_model, :string
    field :credential_validated_at, :utc_datetime_usec
    field :validation_request_id, :string
    field :authorized_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :provider_credential, ProviderCredential
    belongs_to :capture_run, CaptureRun
    belongs_to :authorized_by_user, User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(
        recovery,
        %Monitor{} = monitor,
        %ProviderCredential{} = credential,
        %ModelValidation{} = validation,
        %CaptureRun{} = run,
        %User{} = user,
        epoch,
        authorized_at
      ) do
    recovery
    |> change(
      epoch: epoch,
      requested_model: validation.requested_model,
      credential_validated_at: validation.validated_at,
      validation_request_id: validation.provider_request_id,
      authorized_at: authorized_at,
      workspace_id: monitor.workspace_id,
      monitor_id: monitor.id,
      provider_credential_id: credential.id,
      capture_run_id: run.id,
      authorized_by_user_id: user.id
    )
    |> validate_required([
      :epoch,
      :requested_model,
      :credential_validated_at,
      :authorized_at,
      :workspace_id,
      :monitor_id,
      :provider_credential_id,
      :capture_run_id,
      :authorized_by_user_id
    ])
    |> validate_number(:epoch, greater_than: 0)
    |> validate_length(:requested_model, min: 1, max: 200)
    |> validate_length(:validation_request_id, max: 200)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:provider_credential_id)
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:authorized_by_user_id)
    |> unique_constraint([:monitor_id, :epoch])
    |> unique_constraint(:capture_run_id)
    |> check_constraint(:epoch, name: :monitor_authentication_recoveries_epoch_check)
    |> check_constraint(:requested_model,
      name: :monitor_authentication_recoveries_requested_model_check
    )
  end
end
