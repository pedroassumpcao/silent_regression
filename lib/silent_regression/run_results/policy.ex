defmodule SilentRegression.RunResults.Policy do
  @moduledoc """
  Small, explicit private-alpha alert policy.

  The policy emits explainable findings, not a quality score. Baseline-relative latency and usage
  checks are conservative operational warnings and run only under exact provenance compatibility.
  """

  alias SilentRegression.Captures.{
    CaptureEvaluation,
    CaptureObservation,
    CaptureRuleResult,
    CaptureRun
  }

  alias SilentRegression.RunResults.Provenance

  @critical_failure_categories [
    :authentication,
    :authorization,
    :invalid_request,
    :request_too_large,
    :malformed_response,
    :model_mismatch,
    :call_cap_exceeded,
    :credential_unavailable,
    :unknown_outcome
  ]
  @warning_failure_categories [:rate_limited, :timeout, :transport, :provider_unavailable]
  @latency_multiplier 3
  @latency_minimum_delta_ms 2_000
  @usage_multiplier 2
  @usage_minimum_delta_tokens 100
  @evidence_item_limit 25

  def findings(%CaptureRun{kind: :baseline}), do: []

  def findings(%CaptureRun{} = run) do
    provenance = Provenance.compare(run, run.baseline_snapshot)

    content_findings(run) ++
      provenance_findings(run, provenance) ++
      provider_failure_findings(run) ++
      model_mismatch_findings(run) ++
      completion_findings(run) ++
      evaluator_error_findings(run) ++
      metric_findings(run, provenance)
  end

  def settings do
    %{
      latency_multiplier: @latency_multiplier,
      latency_minimum_delta_ms: @latency_minimum_delta_ms,
      usage_multiplier: @usage_multiplier,
      usage_minimum_delta_tokens: @usage_minimum_delta_tokens
    }
  end

  defp content_findings(run) do
    run.observations
    |> Enum.flat_map(& &1.evaluations)
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map(fn evaluation ->
      decisive = decisive_failures(evaluation)

      finding(run, "contract:#{evaluation.id}", %{
        category: :contract_failure,
        severity: highest_severity(decisive),
        code: "deterministic_contract_failed",
        title: "Deterministic contract failed",
        explanation: "The captured output failed one or more configured deterministic rules.",
        capture_evaluation_id: evaluation.id,
        evidence: %{
          "evaluation_id" => evaluation.id,
          "observation_id" => evaluation.capture_observation_id,
          "root_rule_id" => evaluation.root_rule_id,
          "decisive_rule_ids" => Enum.map(decisive, & &1.rule_id),
          "failed_rule_ids" =>
            evaluation.rule_results
            |> Enum.filter(&(&1.status == :fail))
            |> Enum.map(& &1.rule_id)
        }
      })
    end)
  end

  defp provenance_findings(_run, %{compatible?: true}), do: []

  defp provenance_findings(run, provenance) do
    [
      finding(run, "operational:incompatible_provenance", %{
        category: :operational_anomaly,
        severity: :critical,
        code: "incompatible_provenance",
        title: "Baseline comparison is unavailable",
        explanation:
          "The run is missing its pinned baseline or its immutable provenance does not match. Baseline-relative comparisons were skipped.",
        evidence: %{
          "baseline_snapshot_id" => run.baseline_snapshot_id,
          "mismatches" => Enum.map(provenance.mismatches, &Atom.to_string/1)
        }
      })
    ]
  end

  defp provider_failure_findings(run) do
    run.observations
    |> Enum.filter(&(&1.status in [:failed, :unknown] and not is_nil(&1.failure_category)))
    |> Enum.group_by(& &1.failure_category)
    |> Enum.map(fn {category, observations} ->
      finding(run, "operational:provider:#{category}", %{
        category: :operational_anomaly,
        severity: failure_severity(category),
        code: "provider_#{category}",
        title: failure_title(category),
        explanation:
          "One or more provider calls did not produce a usable completed observation. This is an operational anomaly, not a content-degradation claim.",
        evidence: affected_observation_evidence(observations)
      })
    end)
  end

  defp model_mismatch_findings(run) do
    observations =
      Enum.filter(run.observations, fn observation ->
        is_binary(observation.requested_model) and is_binary(observation.returned_model) and
          observation.requested_model != observation.returned_model
      end)

    if observations == [] do
      []
    else
      [
        finding(run, "operational:model_mismatch", %{
          category: :operational_anomaly,
          severity: :critical,
          code: "returned_model_mismatch",
          title: "Provider returned a different model",
          explanation:
            "At least one completed call returned a model identifier different from the requested model.",
          evidence:
            affected_observation_evidence(observations, fn observation ->
              %{
                "observation_id" => observation.id,
                "requested_model" => observation.requested_model,
                "returned_model" => observation.returned_model
              }
            end)
        })
      ]
    end
  end

  defp completion_findings(run) do
    observations = Enum.filter(run.observations, &(&1.completion_state == :incomplete))

    if observations == [] do
      []
    else
      [
        finding(run, "operational:incomplete_completion", %{
          category: :operational_anomaly,
          severity: :critical,
          code: "incomplete_completion",
          title: "Provider completion was incomplete",
          explanation:
            "At least one provider response stopped before a complete output was returned. This is an operational anomaly, not a content-degradation claim.",
          evidence: affected_observation_evidence(observations)
        })
      ]
    end
  end

  defp evaluator_error_findings(run) do
    evaluations =
      run.observations
      |> Enum.flat_map(& &1.evaluations)
      |> Enum.filter(&(&1.status == :evaluator_error))

    if evaluations == [] do
      []
    else
      items =
        evaluations
        |> Enum.take(@evidence_item_limit)
        |> Enum.map(fn evaluation ->
          %{
            "evaluation_id" => evaluation.id,
            "observation_id" => evaluation.capture_observation_id,
            "error_code" => get_in(evaluation.error || %{}, ["code"])
          }
        end)

      [
        finding(run, "operational:evaluator_error", %{
          category: :operational_anomaly,
          severity: :critical,
          code: "evaluator_error",
          title: "Deterministic evaluation could not complete",
          explanation:
            "The local evaluator could not safely determine at least one contract outcome. No content-degradation conclusion was made.",
          evidence: %{
            "affected_count" => length(evaluations),
            "items" => items,
            "items_truncated" => length(evaluations) > length(items)
          }
        })
      ]
    end
  end

  defp metric_findings(_run, %{compatible?: false}), do: []

  defp metric_findings(run, %{compatible?: true}) do
    baseline_metrics = baseline_metrics(run)

    latency =
      Enum.filter(run.observations, fn observation ->
        baseline = Map.get(baseline_metrics, observation.case_fingerprint)

        (observation.status == :succeeded and baseline) &&
          metric_exceeded?(
            observation.latency_ms,
            baseline.latency_ms,
            @latency_multiplier,
            @latency_minimum_delta_ms
          )
      end)

    usage =
      Enum.filter(run.observations, fn observation ->
        baseline = Map.get(baseline_metrics, observation.case_fingerprint)

        (observation.status == :succeeded and baseline) &&
          metric_exceeded?(
            total_tokens(observation),
            baseline.total_tokens,
            @usage_multiplier,
            @usage_minimum_delta_tokens
          )
      end)

    latency_finding(run, latency, baseline_metrics) ++ usage_finding(run, usage, baseline_metrics)
  end

  defp latency_finding(_run, [], _baseline_metrics), do: []

  defp latency_finding(run, observations, baseline_metrics) do
    [
      finding(run, "operational:latency_anomaly", %{
        category: :operational_anomaly,
        severity: :warning,
        code: "latency_above_baseline",
        title: "Latency is materially above baseline",
        explanation:
          "At least one successful call exceeded the explicit baseline-relative latency warning threshold.",
        evidence:
          metric_evidence(
            observations,
            baseline_metrics,
            :latency_ms,
            @latency_multiplier,
            @latency_minimum_delta_ms
          )
      })
    ]
  end

  defp usage_finding(_run, [], _baseline_metrics), do: []

  defp usage_finding(run, observations, baseline_metrics) do
    [
      finding(run, "operational:usage_anomaly", %{
        category: :operational_anomaly,
        severity: :warning,
        code: "usage_above_baseline",
        title: "Token usage is materially above baseline",
        explanation:
          "At least one successful call exceeded the explicit baseline-relative token-usage warning threshold.",
        evidence:
          metric_evidence(
            observations,
            baseline_metrics,
            :total_tokens,
            @usage_multiplier,
            @usage_minimum_delta_tokens
          )
      })
    ]
  end

  defp baseline_metrics(run) do
    run.baseline_snapshot.members
    |> Enum.group_by(& &1.case_fingerprint, & &1.capture_observation)
    |> Map.new(fn {fingerprint, observations} ->
      {fingerprint,
       %{
         latency_ms: observations |> Enum.map(&(&1.latency_ms || 0)) |> Enum.max(fn -> 0 end),
         total_tokens: observations |> Enum.map(&total_tokens/1) |> Enum.max(fn -> 0 end)
       }}
    end)
  end

  defp decisive_failures(%CaptureEvaluation{} = evaluation) do
    by_id = Map.new(evaluation.rule_results, &{&1.rule_id, &1})

    case Map.get(by_id, evaluation.root_rule_id) do
      nil -> Enum.filter(evaluation.rule_results, &(&1.status == :fail))
      root -> decisive_failures(root, by_id)
    end
  end

  defp decisive_failures(%CaptureRuleResult{status: status}, _by_id) when status != :fail, do: []

  defp decisive_failures(%CaptureRuleResult{rule_type: "all"} = result, by_id) do
    failures =
      result.child_rule_ids
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&decisive_failures(&1, by_id))

    if failures == [], do: [result], else: failures
  end

  defp decisive_failures(%CaptureRuleResult{} = result, _by_id), do: [result]

  defp highest_severity(results) do
    if Enum.any?(results, &(&1.severity == :critical)), do: :critical, else: :warning
  end

  defp failure_severity(category) when category in @critical_failure_categories, do: :critical
  defp failure_severity(category) when category in @warning_failure_categories, do: :warning
  defp failure_severity(_category), do: :critical

  defp failure_title(:authentication), do: "Provider rejected the credential"
  defp failure_title(:authorization), do: "Provider access was denied"
  defp failure_title(:rate_limited), do: "Provider rate limit interrupted the run"
  defp failure_title(:invalid_request), do: "Provider rejected the request"
  defp failure_title(:request_too_large), do: "Provider rejected the request size"
  defp failure_title(:timeout), do: "Provider request timed out"
  defp failure_title(:transport), do: "Provider transport failed"
  defp failure_title(:provider_unavailable), do: "Provider was unavailable"
  defp failure_title(:malformed_response), do: "Provider returned an unusable response"
  defp failure_title(:model_mismatch), do: "Provider model did not match"
  defp failure_title(:call_cap_exceeded), do: "Run reached its provider-call cap"
  defp failure_title(:credential_unavailable), do: "Provider credential was unavailable"
  defp failure_title(:unknown_outcome), do: "Provider-call outcome is unknown"
  defp failure_title(_category), do: "Provider call failed"

  defp affected_observation_evidence(
         observations,
         mapper \\ &default_observation_evidence/1
       ) do
    items = observations |> Enum.take(@evidence_item_limit) |> Enum.map(mapper)

    %{
      "affected_count" => length(observations),
      "items" => items,
      "items_truncated" => length(observations) > length(items)
    }
  end

  defp default_observation_evidence(%CaptureObservation{} = observation) do
    %{
      "observation_id" => observation.id,
      "case_key" => observation.case_version.case_key,
      "failure_category" => atom_string(observation.failure_category)
    }
  end

  defp metric_evidence(observations, baseline_metrics, metric, multiplier, minimum_delta) do
    items =
      observations
      |> Enum.take(@evidence_item_limit)
      |> Enum.map(fn observation ->
        baseline = Map.fetch!(baseline_metrics, observation.case_fingerprint)
        observed = observation_metric(observation, metric)
        reference = Map.fetch!(baseline, metric)

        %{
          "observation_id" => observation.id,
          "case_key" => observation.case_version.case_key,
          "observed" => observed,
          "baseline_maximum" => reference,
          "multiplier" => multiplier,
          "minimum_delta" => minimum_delta,
          "threshold" => max(reference * multiplier, reference + minimum_delta)
        }
      end)

    %{
      "affected_count" => length(observations),
      "items" => items,
      "items_truncated" => length(observations) > length(items)
    }
  end

  defp metric_exceeded?(observed, reference, multiplier, minimum_delta)
       when is_integer(observed) and is_integer(reference) do
    observed > reference * multiplier and observed > reference + minimum_delta
  end

  defp metric_exceeded?(_observed, _reference, _multiplier, _minimum_delta), do: false

  defp observation_metric(observation, :latency_ms), do: observation.latency_ms || 0
  defp observation_metric(observation, :total_tokens), do: total_tokens(observation)

  defp total_tokens(observation),
    do: (observation.input_tokens || 0) + (observation.output_tokens || 0)

  defp finding(run, suffix, attrs) do
    attrs
    |> Map.put(:identity_key, "run:#{run.id}:#{suffix}")
    |> Map.put_new(:capture_evaluation_id, nil)
  end

  defp atom_string(nil), do: nil
  defp atom_string(value), do: Atom.to_string(value)
end
