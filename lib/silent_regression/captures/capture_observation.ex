defmodule SilentRegression.Captures.CaptureObservation do
  @moduledoc """
  Immutable provider evidence for one planned case/sample capture.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.{CaptureEvaluation, CaptureRun, ProviderAttempt}
  alias SilentRegression.Monitors.CaseVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:planned, :running, :retrying, :succeeded, :failed, :unknown, :cancelled]
  @completion_states [:complete, :incomplete, :unknown]
  @failure_categories [
    :authentication,
    :authorization,
    :rate_limited,
    :invalid_request,
    :request_too_large,
    :timeout,
    :transport,
    :provider_unavailable,
    :malformed_response,
    :model_mismatch,
    :call_cap_exceeded,
    :credential_unavailable,
    :unknown_outcome
  ]

  schema "capture_observations" do
    field :sample_index, :integer
    field :status, Ecto.Enum, values: @statuses, default: :planned
    field :case_fingerprint, :string
    field :request_fingerprint, :string
    field :requested_model, :string
    field :returned_model, :string
    field :output_text, :string
    field :completion_state, Ecto.Enum, values: @completion_states
    field :finish_reason, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :latency_ms, :integer
    field :provider_request_id, :string
    field :failure_category, Ecto.Enum, values: @failure_categories
    field :failure_message, :string
    field :provider_metadata, :map, default: %{}
    field :captured_at, :utc_datetime_usec
    field :terminal_at, :utc_datetime_usec

    belongs_to :capture_run, CaptureRun
    belongs_to :case_version, CaseVersion
    has_many :provider_attempts, ProviderAttempt
    has_many :evaluations, CaptureEvaluation

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(observation, run, case_version, attrs) do
    observation
    |> cast(attrs, [:sample_index, :case_fingerprint, :request_fingerprint])
    |> put_change(:status, :planned)
    |> put_change(:capture_run_id, run.id)
    |> put_change(:case_version_id, case_version.id)
    |> validate_required([
      :sample_index,
      :status,
      :case_fingerprint,
      :request_fingerprint,
      :capture_run_id,
      :case_version_id
    ])
    |> validate_number(:sample_index, greater_than_or_equal_to: 0)
    |> validate_fingerprints()
    |> add_constraints()
  end

  def lifecycle_changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :status,
      :requested_model,
      :returned_model,
      :output_text,
      :completion_state,
      :finish_reason,
      :input_tokens,
      :output_tokens,
      :latency_ms,
      :provider_request_id,
      :failure_category,
      :failure_message,
      :provider_metadata,
      :captured_at,
      :terminal_at
    ])
    |> validate_required([:status, :provider_metadata])
    |> validate_length(:requested_model, max: 200)
    |> validate_length(:returned_model, max: 200)
    |> validate_length(:finish_reason, max: 200)
    |> validate_length(:provider_request_id, max: 512)
    |> validate_length(:failure_message, max: 1_000)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> add_constraints()
  end

  def statuses, do: @statuses
  def failure_categories, do: @failure_categories

  defp validate_fingerprints(changeset) do
    changeset
    |> validate_format(:case_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:request_fingerprint, ~r/^[0-9a-f]{64}$/)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:case_version_id)
    |> unique_constraint([:capture_run_id, :case_version_id, :sample_index],
      name: :capture_observations_run_case_sample_index
    )
    |> check_constraint(:sample_index, name: :capture_observations_sample_index_check)
    |> check_constraint(:status, name: :capture_observations_status_check)
    |> check_constraint(:completion_state, name: :capture_observations_completion_state_check)
    |> check_constraint(:failure_category, name: :capture_observations_failure_category_check)
    |> check_constraint(:input_tokens, name: :capture_observations_usage_check)
    |> check_constraint(:case_fingerprint, name: :capture_observations_fingerprints_check)
    |> check_constraint(:status, name: :capture_observations_lifecycle_check)
  end
end
