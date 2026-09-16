defmodule SilentRegression.PilotPolicies.Policy do
  @moduledoc """
  Explicit per-workspace private-alpha provider-spend boundaries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pilot_policies" do
    field :daily_run_limit, :integer, default: 20
    field :daily_call_limit, :integer, default: 200
    field :per_run_call_limit, :integer, default: 200

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(policy, workspace_id, attrs \\ %{}) do
    policy
    |> cast(attrs, [:daily_run_limit, :daily_call_limit, :per_run_call_limit])
    |> put_change(:workspace_id, workspace_id)
    |> validate_required([
      :daily_run_limit,
      :daily_call_limit,
      :per_run_call_limit,
      :workspace_id
    ])
    |> validate_number(:daily_run_limit, greater_than: 0, less_than_or_equal_to: 1000)
    |> validate_number(:daily_call_limit, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:per_run_call_limit, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:workspace_id)
    |> check_constraint(:daily_run_limit, name: :pilot_policies_limits_check)
  end
end
