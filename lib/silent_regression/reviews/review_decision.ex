defmodule SilentRegression.Reviews.ReviewDecision do
  @moduledoc """
  One immutable human judgment tied to exact capture evidence.

  Corrections are represented by successor rows. Existing decisions are never updated.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Accounts.User
  alias SilentRegression.Baselines.BaselineSnapshot

  alias SilentRegression.Captures.{
    CaptureEvaluation,
    CaptureObservation,
    CaptureRuleResult,
    CaptureRun
  }

  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.RunResults.Alert
  alias SilentRegression.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @subject_kinds [:alert, :observation]
  @classifications [
    :correct_pass,
    :confirmed_regression,
    :acceptable_variation,
    :contract_needs_revision,
    :test_case_or_baseline_problem,
    :passed_but_should_have_failed,
    :unsure,
    :operational_anomaly
  ]
  @actions [
    :none,
    :prompt_change,
    :case_change,
    :contract_revision,
    :provider_change,
    :operational_follow_up
  ]

  schema "review_decisions" do
    field :review_key, :string
    field :subject_kind, Ecto.Enum, values: @subject_kinds
    field :classification, Ecto.Enum, values: @classifications
    field :action, Ecto.Enum, values: @actions, default: :none
    field :rationale, :string
    field :reviewed_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :monitor, Monitor
    belongs_to :capture_run, CaptureRun
    belongs_to :result_alert, Alert
    belongs_to :capture_observation, CaptureObservation
    belongs_to :capture_evaluation, CaptureEvaluation
    belongs_to :capture_rule_result, CaptureRuleResult
    belongs_to :contract_version, ContractVersion
    belongs_to :baseline_snapshot, BaselineSnapshot
    belongs_to :reviewer_user, User
    belongs_to :supersedes, __MODULE__
    has_one :successor, __MODULE__, foreign_key: :supersedes_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def create_changeset(decision, evidence, %User{} = reviewer, attrs) do
    decision
    |> cast(attrs, [:classification, :action, :rationale, :reviewed_at])
    |> put_change(:review_key, evidence.review_key)
    |> put_change(:subject_kind, evidence.subject_kind)
    |> put_change(:workspace_id, evidence.workspace_id)
    |> put_change(:monitor_id, evidence.monitor_id)
    |> put_change(:capture_run_id, evidence.capture_run_id)
    |> put_change(:result_alert_id, evidence.result_alert_id)
    |> put_change(:capture_observation_id, evidence.capture_observation_id)
    |> put_change(:capture_evaluation_id, evidence.capture_evaluation_id)
    |> put_change(:capture_rule_result_id, evidence.capture_rule_result_id)
    |> put_change(:contract_version_id, evidence.contract_version_id)
    |> put_change(:baseline_snapshot_id, evidence.baseline_snapshot_id)
    |> put_change(:reviewer_user_id, reviewer.id)
    |> put_change(:supersedes_id, evidence.supersedes_id)
    |> validate_required([
      :review_key,
      :subject_kind,
      :classification,
      :action,
      :reviewed_at,
      :workspace_id,
      :monitor_id,
      :capture_run_id,
      :contract_version_id,
      :reviewer_user_id
    ])
    |> validate_length(:review_key, min: 1, max: 200)
    |> validate_length(:rationale, min: 1, max: 2_000)
    |> add_constraints()
  end

  def classifications, do: @classifications
  def actions, do: @actions

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:monitor_id)
    |> foreign_key_constraint(:capture_run_id)
    |> foreign_key_constraint(:result_alert_id)
    |> foreign_key_constraint(:capture_observation_id)
    |> foreign_key_constraint(:capture_evaluation_id)
    |> foreign_key_constraint(:capture_rule_result_id)
    |> foreign_key_constraint(:contract_version_id)
    |> foreign_key_constraint(:baseline_snapshot_id)
    |> foreign_key_constraint(:reviewer_user_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint([:workspace_id, :review_key], name: :review_decisions_one_root_index)
    |> unique_constraint(:supersedes_id, name: :review_decisions_one_successor_index)
    |> check_constraint(:subject_kind, name: :review_decisions_subject_kind_check)
    |> check_constraint(:classification, name: :review_decisions_classification_check)
    |> check_constraint(:action, name: :review_decisions_action_check)
    |> check_constraint(:subject_kind, name: :review_decisions_subject_check)
    |> check_constraint(:capture_rule_result_id,
      name: :review_decisions_rule_evaluation_check
    )
    |> check_constraint(:rationale, name: :review_decisions_rationale_check)
    |> check_constraint(:supersedes_id, name: :review_decisions_supersedes_check)
  end
end
