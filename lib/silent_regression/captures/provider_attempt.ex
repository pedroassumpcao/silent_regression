defmodule SilentRegression.Captures.ProviderAttempt do
  @moduledoc """
  One pre-reserved provider network attempt in the immutable spend ledger.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.{CaptureObservation, CaptureRun}
  alias SilentRegression.Monitors.Fingerprint

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:started, :succeeded, :failed, :unknown]

  schema "provider_attempts" do
    field :attempt_number, :integer
    field :status, Ecto.Enum, values: @statuses, default: :started
    field :client_request_id, :string
    field :request_mode, Ecto.Enum, values: [:legacy_wrapped_v1, :provider_native_v1]
    field :request_schema_version, :integer
    field :request_fingerprint, :string
    field :request_artifact, :map
    field :provider_request_id, :string
    field :retryable, :boolean

    field :failure_category, Ecto.Enum,
      values: SilentRegression.Captures.CaptureObservation.failure_categories()

    field :failure_message, :string
    field :latency_ms, :integer
    field :started_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :capture_run, CaptureRun
    belongs_to :capture_observation, CaptureObservation

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attempt, run, observation, attrs) do
    attempt
    |> cast(attrs, [
      :attempt_number,
      :client_request_id,
      :request_mode,
      :request_schema_version,
      :request_fingerprint,
      :request_artifact,
      :started_at,
      :lease_expires_at
    ])
    |> put_change(:status, :started)
    |> put_change(:capture_run_id, run.id)
    |> put_change(:capture_observation_id, observation.id)
    |> validate_required([
      :attempt_number,
      :status,
      :client_request_id,
      :request_mode,
      :request_schema_version,
      :request_fingerprint,
      :request_artifact,
      :started_at,
      :lease_expires_at,
      :capture_run_id,
      :capture_observation_id
    ])
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_length(:client_request_id, min: 1, max: 512)
    |> validate_number(:request_schema_version, equal_to: 1)
    |> validate_format(:request_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_request_receipt()
    |> add_constraints()
  end

  def result_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :status,
      :provider_request_id,
      :retryable,
      :failure_category,
      :failure_message,
      :latency_ms,
      :finished_at
    ])
    |> validate_required([:status, :retryable, :finished_at])
    |> validate_length(:provider_request_id, max: 512)
    |> validate_length(:failure_message, max: 1_000)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> add_constraints()
  end

  def statuses, do: @statuses

  defp validate_request_receipt(changeset) do
    artifact = get_field(changeset, :request_artifact)
    mode = get_field(changeset, :request_mode)
    schema_version = get_field(changeset, :request_schema_version)
    fingerprint = get_field(changeset, :request_fingerprint)

    if is_map(artifact) and mode in [:legacy_wrapped_v1, :provider_native_v1] and
         artifact["request_mode"] == Atom.to_string(mode) and
         artifact["request_schema_version"] == schema_version and
         Fingerprint.digest(artifact) == fingerprint do
      changeset
    else
      add_error(changeset, :request_artifact, "does not match its immutable receipt")
    end
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:capture_observation_id)
    |> unique_constraint([:capture_observation_id, :attempt_number])
    |> unique_constraint(:client_request_id)
    |> check_constraint(:attempt_number, name: :provider_attempts_attempt_number_check)
    |> check_constraint(:status, name: :provider_attempts_status_check)
    |> check_constraint(:request_artifact, name: :provider_attempts_request_artifact_check)
    |> check_constraint(:failure_category, name: :provider_attempts_failure_category_check)
    |> check_constraint(:latency_ms, name: :provider_attempts_latency_check)
    |> check_constraint(:lease_expires_at, name: :provider_attempts_lease_check)
    |> check_constraint(:status, name: :provider_attempts_lifecycle_check)
  end
end
