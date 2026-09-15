defmodule SilentRegression.ContractAuthoring.ContractFixture do
  @moduledoc """
  Customer-authored expected output used to validate one contract version locally.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Contracts.Limits

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contract_fixtures" do
    field :name, :string
    field :position, :integer
    field :output_text, :string
    field :expected_status, Ecto.Enum, values: [:pass, :fail]
    field :expected_rule_statuses, :map, default: %{}
    field :fingerprint, :string

    belongs_to :contract_version, ContractVersion
    belongs_to :created_by_user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def create_changeset(fixture, %ContractVersion{} = contract_version, %User{} = user, attrs) do
    fixture
    |> change(Map.take(attrs, content_fields()))
    |> change(contract_version_id: contract_version.id, created_by_user_id: user.id)
    |> validate_content()
    |> add_constraints()
  end

  def update_changeset(fixture, attrs) do
    fixture
    |> change(Map.take(attrs, content_fields()))
    |> validate_content()
    |> add_constraints()
  end

  def pending_judgment_changeset(fixture, fingerprint) do
    fixture
    |> change(expected_rule_statuses: %{}, fingerprint: fingerprint)
    |> add_constraints()
  end

  defp content_fields do
    [:name, :position, :output_text, :expected_status, :expected_rule_statuses, :fingerprint]
  end

  defp validate_content(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([
      :name,
      :position,
      :expected_status,
      :expected_rule_statuses,
      :fingerprint,
      :contract_version_id,
      :created_by_user_id
    ])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_output()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_format(:fingerprint, ~r/^[0-9a-f]{64}$/)
  end

  defp validate_output(changeset) do
    validate_change(changeset, :output_text, fn :output_text, output_text ->
      cond do
        not is_binary(output_text) ->
          [output_text: "must be text"]

        not String.valid?(output_text) ->
          [output_text: "must be valid UTF-8"]

        byte_size(output_text) > Limits.output_bytes() ->
          [output_text: "exceeds the output limit"]

        true ->
          []
      end
    end)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint([:contract_version_id, :position])
    |> check_constraint(:position, name: :contract_fixtures_position_check)
    |> check_constraint(:expected_status, name: :contract_fixtures_expected_status_check)
    |> check_constraint(:fingerprint, name: :contract_fixtures_fingerprint_check)
  end
end
