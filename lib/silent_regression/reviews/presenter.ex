defmodule SilentRegression.Reviews.Presenter do
  @moduledoc false

  alias SilentRegression.Reviews.ReviewDecision
  alias SilentRegression.RunResults.SafeValue

  def decision(%{decision: %ReviewDecision{} = decision, current?: current?}) do
    %{
      id: decision.id,
      review_key: decision.review_key,
      subject_kind: decision.subject_kind,
      classification: decision.classification,
      action: decision.action,
      rationale: SafeValue.text(decision.rationale),
      reviewed_at: decision.reviewed_at,
      reviewed_by: reviewer_email(decision.reviewer_user),
      current: current?,
      supersedes_id: decision.supersedes_id,
      capture_run_id: decision.capture_run_id,
      result_alert_id: decision.result_alert_id,
      capture_observation_id: decision.capture_observation_id,
      capture_evaluation_id: decision.capture_evaluation_id,
      capture_rule_result_id: decision.capture_rule_result_id,
      contract_version_id: decision.contract_version_id,
      baseline_snapshot_id: decision.baseline_snapshot_id
    }
  end

  def summary(summary) do
    %{
      current_count: summary.current_count,
      classification_counts: summary.classification_counts,
      action_counts: summary.action_counts,
      changed_judgment_count: summary.changed_judgment_count,
      superseded_count: summary.superseded_count
    }
  end

  defp reviewer_email(%Ecto.Association.NotLoaded{}), do: nil
  defp reviewer_email(nil), do: nil
  defp reviewer_email(user), do: user.email
end
