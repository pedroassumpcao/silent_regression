defmodule SilentRegression.Baselines.Health do
  @moduledoc false

  alias SilentRegression.Baselines.BaselineSnapshot

  @terminal_run_statuses [:succeeded, :partial_failed, :failed, :cancelled, :needs_review]

  def summarize(%BaselineSnapshot{capture_run: run} = snapshot) when not is_nil(run) do
    observations = run.observations
    status_counts = frequencies(observations, & &1.status)
    completion_counts = frequencies(observations, &completion_bucket/1)

    evaluations =
      observations
      |> Enum.flat_map(& &1.evaluations)
      |> Enum.filter(
        &(&1.contract_version_id == snapshot.contract_version_id and
            &1.evaluator_engine_version == snapshot.evaluator_engine_version)
      )

    evaluation_counts = frequencies(evaluations, & &1.status)
    model_mismatch_count = Enum.count(observations, &model_mismatch?/1)
    missing_observation_count = max(run.planned_call_count - length(observations), 0)

    missing_evaluation_count =
      max(Map.get(status_counts, :succeeded, 0) - length(evaluations), 0)

    common_blockers =
      []
      |> blocker(
        run.status in @terminal_run_statuses,
        "capture_in_progress",
        "Wait for every planned observation to reach a terminal state."
      )
      |> blocker(
        run.status == :succeeded,
        "provider_outcomes_incomplete",
        "Every planned provider call must finish successfully before baseline approval."
      )
      |> blocker(
        missing_observation_count == 0,
        "observations_missing",
        "The run is missing planned observations."
      )
      |> blocker(
        Map.get(completion_counts, :incomplete, 0) == 0,
        "incomplete_completions",
        "Incomplete provider responses cannot enter a baseline."
      )
      |> blocker(
        Map.get(completion_counts, :unknown, 0) == 0,
        "unknown_completions",
        "Unknown provider outcomes cannot enter a baseline."
      )
      |> blocker(
        model_mismatch_count == 0,
        "returned_model_mismatch",
        "The returned model must match the requested model for every observation."
      )
      |> blocker(
        missing_evaluation_count == 0,
        "evaluations_missing",
        "Every successful observation must have deterministic evaluation evidence."
      )
      |> blocker(
        Map.get(evaluation_counts, :evaluator_error, 0) == 0,
        "evaluator_errors",
        "Evaluator errors must be resolved before baseline approval."
      )

    deterministic_failure_count = Map.get(evaluation_counts, :fail, 0)

    %{
      terminal?: run.status in @terminal_run_statuses,
      run_status: run.status,
      planned_call_count: run.planned_call_count,
      maximum_call_count: run.maximum_call_count,
      actual_call_count: Enum.reduce(observations, 0, &(length(&1.provider_attempts) + &2)),
      observation_count: length(observations),
      missing_observation_count: missing_observation_count,
      status_counts: status_counts,
      completion_counts: completion_counts,
      evaluation_counts: evaluation_counts,
      deterministic_failure_count: deterministic_failure_count,
      model_mismatch_count: model_mismatch_count,
      input_tokens: sum(observations, :input_tokens),
      output_tokens: sum(observations, :output_tokens),
      latency_ms: sum(observations, :latency_ms),
      operational_blockers: common_blockers,
      normal_approvable?: common_blockers == [] and deterministic_failure_count == 0,
      exceptional_approvable?: common_blockers == [] and deterministic_failure_count > 0
    }
  end

  def summarize(%BaselineSnapshot{}) do
    %{
      terminal?: false,
      run_status: nil,
      planned_call_count: 0,
      maximum_call_count: 0,
      actual_call_count: 0,
      observation_count: 0,
      missing_observation_count: 0,
      status_counts: %{},
      completion_counts: %{},
      evaluation_counts: %{},
      deterministic_failure_count: 0,
      model_mismatch_count: 0,
      input_tokens: 0,
      output_tokens: 0,
      latency_ms: 0,
      operational_blockers: [
        %{code: "capture_missing", message: "The authorized capture run is unavailable."}
      ],
      normal_approvable?: false,
      exceptional_approvable?: false
    }
  end

  def approval_blockers(summary, :normal) do
    if summary.deterministic_failure_count > 0 do
      summary.operational_blockers ++
        [
          %{
            code: "deterministic_failures",
            message: "Resolve or exceptionally accept deterministic failures before approval."
          }
        ]
    else
      summary.operational_blockers
    end
  end

  def approval_blockers(summary, :exceptional) do
    if summary.deterministic_failure_count > 0 do
      summary.operational_blockers
    else
      summary.operational_blockers ++
        [
          %{
            code: "exception_not_needed",
            message: "This baseline has no deterministic failures and can use normal approval."
          }
        ]
    end
  end

  defp frequencies(collection, callback) do
    Enum.frequencies_by(collection, callback)
  end

  defp completion_bucket(%{status: :unknown}), do: :unknown
  defp completion_bucket(%{completion_state: nil}), do: :not_available
  defp completion_bucket(%{completion_state: state}), do: state

  defp model_mismatch?(observation) do
    is_binary(observation.requested_model) and is_binary(observation.returned_model) and
      observation.requested_model != observation.returned_model
  end

  defp blocker(blockers, true, _code, _message), do: blockers

  defp blocker(blockers, false, code, message) do
    blockers ++ [%{code: code, message: message}]
  end

  defp sum(observations, field) do
    Enum.reduce(observations, 0, &((Map.get(&1, field) || 0) + &2))
  end
end
