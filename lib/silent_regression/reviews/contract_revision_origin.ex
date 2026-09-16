defmodule SilentRegression.Reviews.ContractRevisionOrigin do
  @moduledoc """
  Immutable evidence that one review decision initiated or joined a successor contract draft.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Reviews.ReviewDecision

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "review_contract_revision_origins" do
    belongs_to :review_decision, ReviewDecision
    belongs_to :contract_version, ContractVersion
    belongs_to :actor_user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(origin, %ReviewDecision{} = decision, contract_version, %User{} = actor) do
    origin
    |> change(
      review_decision_id: decision.id,
      contract_version_id: contract_version.id,
      actor_user_id: actor.id
    )
    |> validate_required([:review_decision_id, :contract_version_id, :actor_user_id])
    |> foreign_key_constraint(:review_decision_id)
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:actor_user_id)
    |> unique_constraint(:review_decision_id)
  end
end
