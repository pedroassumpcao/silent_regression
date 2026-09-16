defmodule SilentRegression.RunResults.PolicyTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Baselines.{BaselineMember, BaselineSnapshot}

  alias SilentRegression.Captures.{
    CaptureEvaluation,
    CaptureObservation,
    CaptureRuleResult,
    CaptureRun
  }

  alias SilentRegression.Monitors.CaseVersion

  alias SilentRegression.RunResults.Policy

  test "uses the decisive configured rule severity without inventing an aggregate score" do
    evaluation = %CaptureEvaluation{
      id: Ecto.UUID.generate(),
      capture_observation_id: Ecto.UUID.generate(),
      status: :fail,
      root_rule_id: "contract",
      rule_results: [
        %CaptureRuleResult{
          rule_id: "contract",
          rule_type: "all",
          severity: :critical,
          status: :fail,
          child_rule_ids: ["allowed_label"]
        },
        %CaptureRuleResult{
          rule_id: "allowed_label",
          rule_type: "classification",
          severity: :warning,
          status: :fail,
          child_rule_ids: []
        }
      ]
    }

    observation = %CaptureObservation{
      id: evaluation.capture_observation_id,
      status: :succeeded,
      completion_state: :complete,
      requested_model: "model",
      returned_model: "model",
      evaluations: [evaluation]
    }

    run = %CaptureRun{
      id: Ecto.UUID.generate(),
      kind: :manual,
      baseline_snapshot_id: nil,
      baseline_snapshot: nil,
      observations: [observation]
    }

    findings = Policy.findings(run)
    content = Enum.find(findings, &(&1.category == :contract_failure))
    provenance = Enum.find(findings, &(&1.code == "incompatible_provenance"))

    assert content.severity == :warning
    assert content.evidence["decisive_rule_ids"] == ["allowed_label"]
    assert content.evidence["failed_rule_ids"] == ["contract", "allowed_label"]
    assert provenance.category == :operational_anomaly
    refute Map.has_key?(content, :score)
  end

  test "publishes the conservative operational threshold settings" do
    assert Policy.settings() == %{
             latency_multiplier: 3,
             latency_minimum_delta_ms: 2_000,
             usage_multiplier: 2,
             usage_minimum_delta_tokens: 100
           }
  end

  test "creates explicit baseline-relative metric warnings only after both thresholds are exceeded" do
    ids = %{
      workspace: Ecto.UUID.generate(),
      monitor: Ecto.UUID.generate(),
      version: Ecto.UUID.generate(),
      contract: Ecto.UUID.generate(),
      credential: Ecto.UUID.generate(),
      baseline: Ecto.UUID.generate()
    }

    case_version = %CaseVersion{case_key: "billing-answer"}

    baseline_observation = %CaptureObservation{
      latency_ms: 1_000,
      input_tokens: 60,
      output_tokens: 40
    }

    baseline = %BaselineSnapshot{
      id: ids.baseline,
      workspace_id: ids.workspace,
      monitor_id: ids.monitor,
      monitor_version_id: ids.version,
      contract_version_id: ids.contract,
      provider_credential_id: ids.credential,
      provider: :openai,
      requested_model: "model",
      monitor_fingerprint: fingerprint("monitor"),
      case_set_fingerprint: fingerprint("cases"),
      contract_fingerprint: fingerprint("contract"),
      evaluator_engine_version: "deterministic-v1",
      members: [
        %BaselineMember{
          case_fingerprint: fingerprint("case"),
          capture_observation: baseline_observation
        }
      ]
    }

    observation = %CaptureObservation{
      id: Ecto.UUID.generate(),
      status: :succeeded,
      completion_state: :complete,
      requested_model: "model",
      returned_model: "model",
      case_fingerprint: fingerprint("case"),
      latency_ms: 4_001,
      input_tokens: 200,
      output_tokens: 101,
      case_version: case_version,
      evaluations: []
    }

    run = %CaptureRun{
      id: Ecto.UUID.generate(),
      kind: :manual,
      workspace_id: ids.workspace,
      monitor_id: ids.monitor,
      monitor_version_id: ids.version,
      contract_version_id: ids.contract,
      provider_credential_id: ids.credential,
      provider: :openai,
      requested_model: "model",
      monitor_fingerprint: baseline.monitor_fingerprint,
      case_set_fingerprint: baseline.case_set_fingerprint,
      contract_fingerprint: baseline.contract_fingerprint,
      evaluator_engine_version: baseline.evaluator_engine_version,
      baseline_snapshot_id: baseline.id,
      baseline_snapshot: baseline,
      observations: [observation]
    }

    findings = Policy.findings(run)
    latency = Enum.find(findings, &(&1.code == "latency_above_baseline"))
    usage = Enum.find(findings, &(&1.code == "usage_above_baseline"))

    assert latency.severity == :warning
    assert hd(latency.evidence["items"])["threshold"] == 3_000
    assert usage.severity == :warning
    assert hd(usage.evidence["items"])["threshold"] == 200
  end

  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
