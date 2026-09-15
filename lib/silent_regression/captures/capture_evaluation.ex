defmodule SilentRegression.Captures.CaptureEvaluation do
  @moduledoc """
  Persisted immutable interpretation of a capture observation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.{CaptureObservation, CaptureRuleResult}
  alias SilentRegression.ContractAuthoring.ContractVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "capture_evaluations" do
    field :evaluator_engine_version, :string
    field :contract_fingerprint, :string
    field :status, Ecto.Enum, values: [:pass, :fail, :evaluator_error]
    field :root_rule_id, :string
    field :error, :map
    field :evaluated_at, :utc_datetime_usec

    belongs_to :capture_observation, CaptureObservation
    belongs_to :contract_version, ContractVersion
    has_many :rule_results, CaptureRuleResult

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def create_changeset(evaluation, observation, contract_version, attrs) do
    evaluation
    |> cast(attrs, [
      :evaluator_engine_version,
      :contract_fingerprint,
      :status,
      :root_rule_id,
      :error,
      :evaluated_at
    ])
    |> put_change(:capture_observation_id, observation.id)
    |> put_change(:contract_version_id, contract_version.id)
    |> validate_required([
      :evaluator_engine_version,
      :contract_fingerprint,
      :status,
      :root_rule_id,
      :evaluated_at,
      :capture_observation_id,
      :contract_version_id
    ])
    |> validate_length(:evaluator_engine_version, min: 1, max: 100)
    |> validate_length(:root_rule_id, min: 1, max: 100)
    |> validate_format(:contract_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> foreign_key_constraint(:capture_observation_id)
    |> foreign_key_constraint(:contract_version_id)
    |> unique_constraint(
      [
        :capture_observation_id,
        :contract_version_id,
        :evaluator_engine_version
      ],
      name: :capture_evaluations_observation_contract_engine_index
    )
    |> check_constraint(:status, name: :capture_evaluations_status_check)
    |> check_constraint(:contract_fingerprint, name: :capture_evaluations_fingerprint_check)
    |> check_constraint(:error, name: :capture_evaluations_error_check)
  end
end
