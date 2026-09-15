defmodule SilentRegression.Captures.CaptureRuleResult do
  @moduledoc """
  Immutable explainable result for one rule in a persisted capture evaluation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.CaptureEvaluation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "capture_rule_results" do
    field :position, :integer
    field :rule_id, :string
    field :rule_type, :string
    field :status, Ecto.Enum, values: [:pass, :fail, :evaluator_error]
    field :code, :string
    field :explanation, :string
    field :evidence, :map, default: %{}
    field :child_rule_ids, {:array, :string}, default: []

    belongs_to :capture_evaluation, CaptureEvaluation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def create_changeset(rule_result, evaluation, attrs) do
    rule_result
    |> cast(attrs, [
      :position,
      :rule_id,
      :rule_type,
      :status,
      :code,
      :explanation,
      :evidence,
      :child_rule_ids
    ])
    |> put_change(:capture_evaluation_id, evaluation.id)
    |> validate_required([
      :position,
      :rule_id,
      :rule_type,
      :status,
      :code,
      :explanation,
      :evidence,
      :capture_evaluation_id
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_length(:rule_id, min: 1, max: 100)
    |> validate_length(:rule_type, min: 1, max: 100)
    |> validate_length(:code, min: 1, max: 100)
    |> validate_length(:explanation, min: 1, max: 1_000)
    |> foreign_key_constraint(:capture_evaluation_id)
    |> unique_constraint([:capture_evaluation_id, :rule_id])
    |> unique_constraint([:capture_evaluation_id, :position])
    |> check_constraint(:position, name: :capture_rule_results_position_check)
    |> check_constraint(:status, name: :capture_rule_results_status_check)
  end
end
