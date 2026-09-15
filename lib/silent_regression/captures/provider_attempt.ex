defmodule SilentRegression.Captures.ProviderAttempt do
  @moduledoc """
  One pre-reserved provider network attempt in the immutable spend ledger.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.{CaptureObservation, CaptureRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:started, :succeeded, :failed, :unknown]

  schema "provider_attempts" do
    field :attempt_number, :integer
    field :status, Ecto.Enum, values: @statuses, default: :started
    field :client_request_id, :string
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
    |> cast(attrs, [:attempt_number, :client_request_id, :started_at, :lease_expires_at])
    |> put_change(:status, :started)
    |> put_change(:capture_run_id, run.id)
    |> put_change(:capture_observation_id, observation.id)
    |> validate_required([
      :attempt_number,
      :status,
      :client_request_id,
      :started_at,
      :lease_expires_at,
      :capture_run_id,
      :capture_observation_id
    ])
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_length(:client_request_id, min: 1, max: 512)
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

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:capture_observation_id)
    |> unique_constraint([:capture_observation_id, :attempt_number])
    |> unique_constraint(:client_request_id)
    |> check_constraint(:attempt_number, name: :provider_attempts_attempt_number_check)
    |> check_constraint(:status, name: :provider_attempts_status_check)
    |> check_constraint(:failure_category, name: :provider_attempts_failure_category_check)
    |> check_constraint(:latency_ms, name: :provider_attempts_latency_check)
    |> check_constraint(:lease_expires_at, name: :provider_attempts_lease_check)
    |> check_constraint(:status, name: :provider_attempts_lifecycle_check)
  end
end
