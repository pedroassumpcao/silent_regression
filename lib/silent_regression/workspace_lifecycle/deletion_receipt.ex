defmodule SilentRegression.WorkspaceLifecycle.DeletionReceipt do
  @moduledoc """
  Content-free proof that a workspace closure or deletion request was handled.

  The receipt deliberately has no workspace foreign key so completion evidence
  can remain after all customer-identifying data has been purged.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @request_types [:closure_retention, :explicit_request]
  @statuses [:pending, :cancelled, :completed]

  schema "workspace_deletion_receipts" do
    field :request_id, Ecto.UUID
    field :workspace_fingerprint, :binary, redact: true
    field :request_type, Ecto.Enum, values: @request_types
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :requested_at, :utc_datetime
    field :purge_due_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :cancelled_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def pending_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :request_id,
      :workspace_fingerprint,
      :request_type,
      :requested_at,
      :purge_due_at
    ])
    |> put_change(:status, :pending)
    |> validate_required([
      :request_id,
      :workspace_fingerprint,
      :request_type,
      :requested_at,
      :purge_due_at
    ])
    |> unique_constraint(:request_id)
    |> add_constraints()
  end

  def complete_changeset(receipt, at) do
    receipt
    |> change(status: :completed, completed_at: at, cancelled_at: nil)
    |> add_constraints()
  end

  def cancel_changeset(receipt, at) do
    receipt
    |> change(status: :cancelled, cancelled_at: at, completed_at: nil)
    |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> check_constraint(:request_type, name: :workspace_deletion_receipts_type_check)
    |> check_constraint(:status, name: :workspace_deletion_receipts_status_check)
    |> check_constraint(:workspace_fingerprint,
      name: :workspace_deletion_receipts_fingerprint_check
    )
    |> check_constraint(:status, name: :workspace_deletion_receipts_lifecycle_check)
  end
end
