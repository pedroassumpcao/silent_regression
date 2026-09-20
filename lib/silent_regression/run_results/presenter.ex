defmodule SilentRegression.RunResults.Presenter do
  @moduledoc false

  alias SilentRegression.Captures.{CaptureObservation, CaptureRun}
  alias SilentRegression.RunResults.{Alert, Policy, Provenance, SafeValue}

  def alert(%Alert{} = alert) do
    %{
      id: alert.id,
      category: alert.category,
      severity: alert.severity,
      status: alert.status,
      code: alert.code,
      title: alert.title,
      explanation: alert.explanation,
      evidence: SafeValue.structured(alert.evidence),
      opened_at: alert.opened_at,
      acknowledged_at: alert.acknowledged_at,
      resolved_at: alert.resolved_at,
      resolution_review_decision_id: alert.resolution_review_decision_id,
      acknowledged_by: association_email(alert.acknowledged_by_user),
      resolved_by: association_email(alert.resolved_by_user),
      monitor: association_monitor(alert.monitor),
      run: association_run(alert.capture_run)
    }
  end

  def run_summary(%CaptureRun{} = run, alerts \\ []) do
    observations = run.observations
    evaluations = Enum.flat_map(observations, & &1.evaluations)
    attempts = Enum.flat_map(observations, & &1.provider_attempts)
    comparison = Provenance.compare(run, loaded_association(run.baseline_snapshot))

    %{
      id: run.id,
      kind: run.kind,
      status: run.status,
      provider: run.provider,
      requested_model: run.requested_model,
      baseline_snapshot_id: run.baseline_snapshot_id,
      provenance_compatible: comparison.compatible?,
      provenance_mismatches: comparison.mismatches,
      planned_call_count: run.planned_call_count,
      maximum_call_count: run.maximum_call_count,
      actual_call_count: length(attempts),
      observation_count: length(observations),
      observation_counts: frequencies(observations, & &1.status),
      completion_counts: frequencies(observations, &completion_bucket/1),
      evaluation_counts: frequencies(evaluations, & &1.status),
      contract_evaluation_counts: frequencies(evaluations, & &1.contract_status),
      case_expectation_counts: frequencies(evaluations, & &1.case_expectation_status),
      provider_failure_count: Enum.count(observations, &(&1.status in [:failed, :unknown])),
      model_mismatch_count: Enum.count(observations, &model_mismatch?/1),
      input_tokens: sum(observations, :input_tokens),
      output_tokens: sum(observations, :output_tokens),
      latency_ms: sum(observations, :latency_ms),
      alert_counts: frequencies(alerts, & &1.status),
      critical_alert_count: Enum.count(alerts, &(&1.severity == :critical)),
      warning_alert_count: Enum.count(alerts, &(&1.severity == :warning)),
      started_at: run.started_at,
      completed_at: run.completed_at,
      inserted_at: run.inserted_at
    }
  end

  def run_detail(%CaptureRun{} = run, alerts) do
    %{
      summary: run_summary(run, alerts),
      identity_key: run.identity_key,
      samples_per_case: run.samples_per_case,
      retry_limit: run.retry_limit,
      provenance: provenance(run),
      configuration: configuration(run),
      alert_policy: Policy.settings(),
      alerts: Enum.map(alerts, &alert/1),
      observations:
        run.observations
        |> Enum.sort_by(&{&1.case_version.position, &1.sample_index, &1.id})
        |> Enum.map(&observation/1)
    }
  end

  def diagnostic(%CaptureRun{} = run, alerts) do
    detail = run_detail(run, alerts)

    %{
      schema_version: 1,
      generated_at: DateTime.utc_now(),
      run: Map.drop(detail.summary, [:alert_counts]),
      provenance: detail.provenance,
      alert_policy: detail.alert_policy,
      alerts:
        Enum.map(detail.alerts, fn alert ->
          Map.take(alert, [
            :id,
            :category,
            :severity,
            :status,
            :code,
            :title,
            :explanation,
            :evidence,
            :opened_at,
            :acknowledged_at,
            :resolved_at
          ])
        end),
      observations:
        Enum.map(detail.observations, fn observation ->
          observation
          |> Map.drop([:case, :output])
          |> Map.update!(:provider_metadata, &SafeValue.diagnostic/1)
          |> Map.update!(:evaluations, fn evaluations ->
            Enum.map(evaluations, fn evaluation ->
              evaluation
              |> Map.update!(:rule_results, fn results ->
                Enum.map(results, &Map.drop(&1, [:evidence]))
              end)
              |> Map.update!(
                :case_expectation_results,
                &redact_expectation_evidence/1
              )
            end)
          end)
        end)
    }
    |> SafeValue.diagnostic()
  end

  defp observation(%CaptureObservation{} = observation) do
    %{
      id: observation.id,
      sample_index: observation.sample_index,
      status: observation.status,
      completion_state: observation.completion_state,
      requested_model: observation.requested_model,
      returned_model: observation.returned_model,
      finish_reason: observation.finish_reason,
      input_tokens: observation.input_tokens,
      output_tokens: observation.output_tokens,
      latency_ms: observation.latency_ms,
      provider_request_id: observation.provider_request_id,
      failure_category: observation.failure_category,
      failure_message: SafeValue.text(observation.failure_message),
      provider_metadata: SafeValue.provider_metadata(observation.provider_metadata),
      captured_at: observation.captured_at,
      terminal_at: observation.terminal_at,
      case: %{
        id: observation.case_version.id,
        key: observation.case_version.case_key,
        name: observation.case_version.name,
        input_variables: SafeValue.structured(observation.case_version.input_variables),
        context: SafeValue.text(observation.case_version.frozen_context),
        fingerprint: observation.case_fingerprint,
        expectation_schema_version: observation.case_version.expectation_schema_version,
        expectation_fingerprint: observation.case_version.expectation_fingerprint
      },
      output: SafeValue.text(observation.output_text),
      attempts: Enum.map(observation.provider_attempts, &attempt/1),
      evaluations: Enum.map(observation.evaluations, &evaluation/1)
    }
  end

  defp attempt(attempt) do
    %{
      id: attempt.id,
      attempt_number: attempt.attempt_number,
      status: attempt.status,
      request_mode: attempt.request_mode,
      request_schema_version: attempt.request_schema_version,
      request_fingerprint: attempt.request_fingerprint,
      provider_request_id: attempt.provider_request_id,
      retryable: attempt.retryable,
      failure_category: attempt.failure_category,
      failure_message: SafeValue.text(attempt.failure_message),
      latency_ms: attempt.latency_ms,
      started_at: attempt.started_at,
      finished_at: attempt.finished_at
    }
  end

  defp evaluation(evaluation) do
    %{
      id: evaluation.id,
      status: evaluation.status,
      contract_status: evaluation.contract_status,
      root_rule_id: evaluation.root_rule_id,
      contract_fingerprint: evaluation.contract_fingerprint,
      case_expectation_schema_version: evaluation.case_expectation_schema_version,
      case_expectation_fingerprint: evaluation.case_expectation_fingerprint,
      case_expectation_status: evaluation.case_expectation_status,
      case_expectation_results: expectation_results(evaluation.case_expectation_results),
      case_expectation_error: SafeValue.structured(evaluation.case_expectation_error),
      evaluator_engine_version: evaluation.evaluator_engine_version,
      evaluated_at: evaluation.evaluated_at,
      error: SafeValue.structured(evaluation.error),
      rule_results:
        Enum.map(evaluation.rule_results, fn result ->
          %{
            id: result.id,
            position: result.position,
            rule_id: result.rule_id,
            rule_type: result.rule_type,
            severity: result.severity,
            status: result.status,
            code: result.code,
            explanation: result.explanation,
            evidence: SafeValue.structured(result.evidence),
            child_rule_ids: result.child_rule_ids
          }
        end)
    }
  end

  defp provenance(run) do
    baseline = loaded_association(run.baseline_snapshot)
    comparison = Provenance.compare(run, baseline)

    %{
      compatible: comparison.compatible?,
      mismatches: comparison.mismatches,
      baseline: baseline_provenance(baseline),
      current: run_provenance(run)
    }
  end

  defp baseline_provenance(nil), do: nil

  defp baseline_provenance(baseline) do
    %{
      id: baseline.id,
      status: baseline.status,
      approval_mode: baseline.approval_mode,
      approved_at: baseline.approved_at,
      provider: baseline.provider,
      requested_model: baseline.requested_model,
      monitor_version_id: baseline.monitor_version_id,
      contract_version_id: baseline.contract_version_id,
      provider_credential_id: baseline.provider_credential_id,
      monitor_fingerprint: baseline.monitor_fingerprint,
      case_set_fingerprint: baseline.case_set_fingerprint,
      contract_fingerprint: baseline.contract_fingerprint,
      contract_semantics_fingerprint: baseline.contract_semantics_fingerprint,
      evaluator_engine_version: baseline.evaluator_engine_version
    }
  end

  defp run_provenance(run) do
    %{
      id: run.id,
      provider: run.provider,
      requested_model: run.requested_model,
      monitor_version_id: run.monitor_version_id,
      contract_version_id: run.contract_version_id,
      provider_credential_id: run.provider_credential_id,
      monitor_fingerprint: run.monitor_fingerprint,
      case_set_fingerprint: run.case_set_fingerprint,
      contract_fingerprint: run.contract_fingerprint,
      contract_semantics_fingerprint: run.contract_semantics_fingerprint,
      evaluator_engine_version: run.evaluator_engine_version
    }
  end

  defp configuration(run) do
    version = run.monitor_version

    %{
      monitor_version: version.version,
      system_prompt: SafeValue.text(version.system_prompt),
      user_prompt_template: SafeValue.text(version.user_prompt_template),
      response_format: SafeValue.structured(version.response_format),
      generation_config: SafeValue.structured(version.generation_config)
    }
  end

  defp association_email(%Ecto.Association.NotLoaded{}), do: nil
  defp association_email(nil), do: nil
  defp association_email(user), do: user.email

  defp association_monitor(%Ecto.Association.NotLoaded{}), do: nil
  defp association_monitor(nil), do: nil
  defp association_monitor(monitor), do: %{id: monitor.id, name: monitor.name}

  defp association_run(%Ecto.Association.NotLoaded{}), do: nil
  defp association_run(nil), do: nil

  defp association_run(run) do
    %{id: run.id, kind: run.kind, status: run.status, completed_at: run.completed_at}
  end

  defp loaded_association(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_association(value), do: value

  defp expectation_results(%{"checks" => checks}) when is_list(checks) do
    %{
      checks:
        Enum.map(checks, fn check ->
          %{
            check_id: check["check_id"],
            check_type: check["check_type"],
            status: check["status"],
            code: check["code"],
            explanation: check["explanation"],
            evidence: SafeValue.structured(check["evidence"])
          }
        end)
    }
  end

  defp expectation_results(_results), do: %{checks: []}

  defp redact_expectation_evidence(%{checks: checks} = results) when is_list(checks) do
    Map.put(results, :checks, Enum.map(checks, &Map.drop(&1, [:evidence])))
  end

  defp redact_expectation_evidence(results), do: results

  defp frequencies(collection, callback) do
    collection |> Enum.frequencies_by(callback) |> stringify_keys()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp completion_bucket(%{status: :unknown}), do: :unknown
  defp completion_bucket(%{completion_state: nil}), do: :not_available
  defp completion_bucket(%{completion_state: state}), do: state

  defp model_mismatch?(observation) do
    is_binary(observation.requested_model) and is_binary(observation.returned_model) and
      observation.requested_model != observation.returned_model
  end

  defp sum(observations, field) do
    Enum.reduce(observations, 0, &((Map.get(&1, field) || 0) + &2))
  end
end
