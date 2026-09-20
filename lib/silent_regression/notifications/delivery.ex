defmodule SilentRegression.Notifications.Delivery do
  @moduledoc """
  Durable, deduplicated delivery evidence for one actionable alert recipient.

  The row stores identifiers and bounded status metadata, never an email address or alert evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.RunResults.Alert
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :sent, :failed, :skipped]
  @outcome_reasons [:adapter_error, :preference_disabled, :recipient_unavailable]

  schema "notification_deliveries" do
    field :kind,
          Ecto.Enum,
          values: [
            actionable_alert: "actionable_alert",
            coverage_interrupted: "coverage_interrupted"
          ]

    field :channel, Ecto.Enum, values: [email: "email"]
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attempts, :integer, default: 0
    field :outcome_reason, Ecto.Enum, values: @outcome_reasons
    field :last_attempted_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    field :deduplication_key, :string

    field :coverage_reason,
          Ecto.Enum,
          values: [
            workspace_run_limit: "workspace_run_limit",
            workspace_call_limit: "workspace_call_limit"
          ]

    field :coverage_retry_at, :utc_datetime
    field :coverage_intended_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :result_alert, Alert
    belongs_to :monitor, Monitor
    belongs_to :recipient_user, User

    timestamps(type: :utc_datetime_usec)
  end

  def attempt_changeset(delivery, at) do
    delivery
    |> change(
      attempts: delivery.attempts + 1,
      status: :pending,
      outcome_reason: nil,
      last_attempted_at: at
    )
    |> validate_number(:attempts, greater_than: 0, less_than_or_equal_to: 5)
    |> add_constraints()
  end

  def sent_changeset(delivery, at) do
    delivery
    |> change(status: :sent, outcome_reason: nil, sent_at: at)
    |> add_constraints()
  end

  def failed_changeset(delivery) do
    delivery
    |> change(status: :failed, outcome_reason: :adapter_error, sent_at: nil)
    |> add_constraints()
  end

  def skipped_changeset(delivery, reason) when reason in @outcome_reasons do
    delivery
    |> change(status: :skipped, outcome_reason: reason, sent_at: nil)
    |> add_constraints()
  end

  def statuses, do: @statuses

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:result_alert_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:recipient_user_id)
    |> unique_constraint([:result_alert_id, :recipient_user_id, :channel])
    |> unique_constraint([:deduplication_key, :recipient_user_id, :channel],
      name: :notification_deliveries_deduplication_key_index
    )
    |> check_constraint(:kind, name: :notification_deliveries_kind_check)
    |> check_constraint(:channel, name: :notification_deliveries_channel_check)
    |> check_constraint(:status, name: :notification_deliveries_status_check)
    |> check_constraint(:attempts, name: :notification_deliveries_attempts_check)
    |> check_constraint(:outcome_reason,
      name: :notification_deliveries_outcome_reason_check
    )
    |> check_constraint(:status, name: :notification_deliveries_lifecycle_check)
    |> check_constraint(:kind, name: :notification_deliveries_subject_check)
    |> check_constraint(:deduplication_key,
      name: :notification_deliveries_deduplication_key_check
    )
  end
end
