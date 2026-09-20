defmodule SilentRegression.ContractAuthoring.RescoreItem do
  @moduledoc """
  One pinned historical observation in a durable contract rescore run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.{CaptureEvaluation, CaptureObservation}
  alias SilentRegression.ContractAuthoring.RescoreRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contract_rescore_items" do
    field :position, :integer

    field :status, Ecto.Enum,
      values: [:pending, :pass, :fail, :evaluator_error],
      default: :pending

    field :error, :map
    field :processed_at, :utc_datetime_usec

    belongs_to :contract_rescore_run, RescoreRun
    belongs_to :capture_observation, CaptureObservation
    belongs_to :capture_evaluation, CaptureEvaluation

    timestamps(type: :utc_datetime_usec)
  end

  def success_changeset(item, evaluation, at) when evaluation.status in [:pass, :fail] do
    item
    |> change(
      status: evaluation.status,
      capture_evaluation_id: evaluation.id,
      processed_at: at
    )
    |> add_constraints()
  end

  def evaluator_error_changeset(item, evaluation, error, at) do
    item
    |> change(
      status: :evaluator_error,
      capture_evaluation_id: evaluation && evaluation.id,
      error: error,
      processed_at: at
    )
    |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:contract_rescore_run_id)
    |> foreign_key_constraint(:capture_observation_id)
    |> foreign_key_constraint(:capture_evaluation_id)
    |> unique_constraint([:contract_rescore_run_id, :capture_observation_id])
    |> unique_constraint([:contract_rescore_run_id, :position])
    |> check_constraint(:position, name: :contract_rescore_items_position_check)
    |> check_constraint(:status, name: :contract_rescore_items_status_check)
    |> check_constraint(:status, name: :contract_rescore_items_lifecycle_check)
  end
end
