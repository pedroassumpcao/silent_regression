defmodule SilentRegression.ContractAuthoring.RescoreRun do
  @moduledoc """
  Durable progress for activating one contract candidate against a pinned history set.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.ContractAuthoring.{ContractVersion, RescoreItem}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses [:pending, :running, :succeeded, :failed]

  schema "contract_rescore_runs" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :batch_size, :integer
    field :total_count, :integer
    field :processed_count, :integer, default: 0
    field :pass_count, :integer, default: 0
    field :fail_count, :integer, default: 0
    field :evaluator_error_count, :integer, default: 0
    field :error, :map
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :contract_version, ContractVersion
    belongs_to :predecessor_contract_version, ContractVersion
    belongs_to :requested_by_user, User
    has_many :items, RescoreItem, foreign_key: :contract_rescore_run_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(run, contract_version, predecessor, user, attrs) do
    run
    |> cast(attrs, [:batch_size, :total_count, :requested_at])
    |> put_change(:status, :pending)
    |> put_change(:processed_count, 0)
    |> put_change(:pass_count, 0)
    |> put_change(:fail_count, 0)
    |> put_change(:evaluator_error_count, 0)
    |> put_change(:contract_version_id, contract_version.id)
    |> put_change(:predecessor_contract_version_id, predecessor && predecessor.id)
    |> put_change(:requested_by_user_id, user.id)
    |> validate_required([
      :status,
      :batch_size,
      :total_count,
      :requested_at,
      :contract_version_id,
      :requested_by_user_id
    ])
    |> validate_number(:batch_size, greater_than: 0, less_than_or_equal_to: 500)
    |> validate_number(:total_count, greater_than: 0)
    |> add_constraints()
  end

  def running_changeset(%__MODULE__{status: :pending} = run, at) do
    run
    |> change(status: :running, started_at: at)
    |> add_constraints()
  end

  def running_changeset(%__MODULE__{status: :running} = run, _at), do: change(run)

  def progress_changeset(%__MODULE__{status: :running} = run, counts) do
    run
    |> cast(counts, [:processed_count, :pass_count, :fail_count, :evaluator_error_count])
    |> validate_counts()
    |> add_constraints()
  end

  def succeeded_changeset(%__MODULE__{status: :running} = run, counts, at) do
    run
    |> cast(counts, [:processed_count, :pass_count, :fail_count, :evaluator_error_count])
    |> change(status: :succeeded, completed_at: at)
    |> validate_counts()
    |> add_constraints()
  end

  def failed_changeset(%__MODULE__{status: status} = run, counts, error, at)
      when status in [:pending, :running] do
    started_at = run.started_at || at

    run
    |> cast(counts, [:processed_count, :pass_count, :fail_count, :evaluator_error_count])
    |> change(status: :failed, started_at: started_at, completed_at: at, error: error)
    |> validate_required(:error)
    |> validate_counts()
    |> add_constraints()
  end

  def statuses, do: @statuses

  defp validate_counts(changeset) do
    changeset
    |> validate_number(:processed_count, greater_than_or_equal_to: 0)
    |> validate_number(:pass_count, greater_than_or_equal_to: 0)
    |> validate_number(:fail_count, greater_than_or_equal_to: 0)
    |> validate_number(:evaluator_error_count, greater_than_or_equal_to: 0)
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:predecessor_contract_version_id)
    |> foreign_key_constraint(:requested_by_user_id)
    |> unique_constraint(:contract_version_id)
    |> check_constraint(:status, name: :contract_rescore_runs_status_check)
    |> check_constraint(:processed_count, name: :contract_rescore_runs_counts_check)
    |> check_constraint(:status, name: :contract_rescore_runs_lifecycle_check)
  end
end
