defmodule SilentRegression.OperationalHealth.Heartbeat do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @names [:scheduler_dispatch, :workspace_purge]
  @statuses [:ok, :error]

  schema "operational_heartbeats" do
    field :name, Ecto.Enum, values: @names
    field :status, Ecto.Enum, values: @statuses
    field :observed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(heartbeat, attrs) do
    heartbeat
    |> cast(attrs, [:name, :status, :observed_at])
    |> validate_required([:name, :status, :observed_at])
    |> unique_constraint(:name)
    |> check_constraint(:name, name: :operational_heartbeats_name_check)
    |> check_constraint(:status, name: :operational_heartbeats_status_check)
  end
end
