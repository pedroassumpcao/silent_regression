defmodule SilentRegression.GuidedDemoTest do
  use ExUnit.Case, async: true

  alias SilentRegression.GuidedDemo

  test "the sealed fixture exposes an exact case regression without provider work" do
    scenario = GuidedDemo.scenario()

    assert scenario.scenario_version == "credential-free-demo-v1"
    assert scenario.provider_calls == 0
    assert byte_size(scenario.sealed_fingerprint) == 64
    assert scenario.sealed_fingerprint == GuidedDemo.scenario().sealed_fingerprint

    assert scenario.reference.output == "billing"
    assert scenario.reference.contract_status == "pass"
    assert scenario.reference.case_expectation_status == "pass"
    assert scenario.reference.overall_status == "pass"

    assert scenario.recurring.output == "technical"
    assert scenario.recurring.contract_status == "pass"
    assert scenario.recurring.case_expectation_status == "fail"
    assert scenario.recurring.overall_status == "fail"

    assert [case_result] = scenario.recurring.case_expectation_results
    assert case_result.check_id == "expected_route"
    assert case_result.code == "expected_label_mismatch"
    assert scenario.incident.signature =~ "case_expectation_failure"
  end
end
