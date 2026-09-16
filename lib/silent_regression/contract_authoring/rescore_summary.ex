defmodule SilentRegression.ContractAuthoring.RescoreSummary do
  @moduledoc """
  Immutable summary proving that stored successful observations were evaluated before activation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.ContractAuthoring.ContractVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contract_rescore_summaries" do
    field :observation_count, :integer
    field :pass_count, :integer
    field :fail_count, :integer
    field :evaluator_error_count, :integer
    field :interpretation_changed, :boolean
    field :rescored_at, :utc_datetime_usec

    belongs_to :contract_version, ContractVersion
    belongs_to :predecessor_contract_version, ContractVersion

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(summary, contract_version, predecessor, attrs) do
    summary
    |> cast(attrs, [
      :observation_count,
      :pass_count,
      :fail_count,
      :evaluator_error_count,
      :interpretation_changed,
      :rescored_at
    ])
    |> put_change(:contract_version_id, contract_version.id)
    |> put_change(:predecessor_contract_version_id, predecessor && predecessor.id)
    |> validate_required([
      :observation_count,
      :pass_count,
      :fail_count,
      :evaluator_error_count,
      :interpretation_changed,
      :rescored_at,
      :contract_version_id
    ])
    |> validate_number(:observation_count, greater_than_or_equal_to: 0)
    |> validate_number(:pass_count, greater_than_or_equal_to: 0)
    |> validate_number(:fail_count, greater_than_or_equal_to: 0)
    |> validate_number(:evaluator_error_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:predecessor_contract_version_id)
    |> unique_constraint(:contract_version_id)
    |> check_constraint(:observation_count, name: :contract_rescore_summaries_counts_check)
  end
end
