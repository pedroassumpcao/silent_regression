defmodule SilentRegression.ContractAuthoring.CoverageWaiver do
  @moduledoc """
  An owner-attributed exception for missing proof on one exact contract rule.

  The rule fingerprint prevents a waiver from silently surviving a semantic
  edit, even when the stable rule ID remains the same.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ContractAuthoring.ContractVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contract_coverage_waivers" do
    field :rule_id, :string
    field :rule_fingerprint, :string
    field :rationale, :string

    belongs_to :contract_version, ContractVersion
    belongs_to :waived_by_user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(waiver, %ContractVersion{} = contract_version, %User{} = user, attrs) do
    waiver
    |> change(Map.take(attrs, [:rule_id, :rule_fingerprint, :rationale]))
    |> change(contract_version_id: contract_version.id, waived_by_user_id: user.id)
    |> update_change(:rationale, &String.trim/1)
    |> validate_required([
      :rule_id,
      :rule_fingerprint,
      :rationale,
      :contract_version_id,
      :waived_by_user_id
    ])
    |> validate_format(:rule_id, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> validate_format(:rule_fingerprint, ~r/^[0-9a-f]{64}$/)
    |> validate_length(:rationale, min: 20, max: 1000)
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:waived_by_user_id)
    |> unique_constraint([:contract_version_id, :rule_id])
    |> check_constraint(:rule_id, name: :contract_coverage_waivers_rule_id_check)
    |> check_constraint(:rule_fingerprint,
      name: :contract_coverage_waivers_rule_fingerprint_check
    )
    |> check_constraint(:rationale, name: :contract_coverage_waivers_rationale_check)
  end
end
