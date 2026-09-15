defmodule SilentRegression.Captures.SchemaTest do
  use SilentRegression.DataCase, async: true

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Captures.{
    CaptureEvaluation,
    CaptureObservation,
    CaptureRuleResult,
    CaptureRun,
    ProviderAttempt
  }

  setup do
    scope = workspace_scope_fixture()
    fixture = baseline_ready_monitor_fixture(scope)
    case_version = hd(fixture.version.cases)

    associations = %{
      workspace_id: scope.workspace.id,
      monitor_id: fixture.monitor.id,
      monitor_version_id: fixture.version.id,
      contract_version_id: fixture.contract.id,
      provider_credential_id: fixture.credential.id,
      created_by_user_id: scope.user.id
    }

    attrs = %{
      identity_key: "schema-test-#{System.unique_integer([:positive])}",
      kind: :baseline,
      provider: fixture.version.provider,
      requested_model: fixture.version.requested_model,
      monitor_fingerprint: fixture.version.fingerprint,
      case_set_fingerprint: fixture.version.case_set_fingerprint,
      contract_fingerprint: fixture.contract.fingerprint,
      evaluator_engine_version: fixture.contract.evaluator_engine_version,
      samples_per_case: 1,
      retry_limit: 1,
      planned_call_count: 1,
      maximum_call_count: 2
    }

    run =
      %CaptureRun{}
      |> CaptureRun.create_changeset(associations, attrs)
      |> Repo.insert!()

    observation =
      %CaptureObservation{}
      |> CaptureObservation.create_changeset(run, case_version, %{
        sample_index: 0,
        case_fingerprint: case_version.fingerprint,
        request_fingerprint: digest("request")
      })
      |> Repo.insert!()

    %{case_version: case_version, fixture: fixture, observation: observation, run: run}
  end

  test "database guards keep the run plan and terminal observation evidence immutable", %{
    observation: observation,
    run: run
  } do
    assert_raise Postgrex.Error, ~r/capture run plan is immutable/, fn ->
      run |> change(requested_model: "different-model") |> Repo.update!()
    end

    now = DateTime.utc_now()

    observation =
      observation
      |> CaptureObservation.lifecycle_changeset(%{
        status: :succeeded,
        requested_model: run.requested_model,
        returned_model: run.requested_model,
        output_text: "approved",
        completion_state: :complete,
        finish_reason: "stop",
        input_tokens: 10,
        output_tokens: 1,
        latency_ms: 25,
        provider_request_id: "provider-request-1",
        provider_metadata: %{"api_version" => "test"},
        captured_at: now,
        terminal_at: now
      })
      |> Repo.update!()

    assert_raise Postgrex.Error, ~r/terminal capture observation is immutable/, fn ->
      observation |> change(output_text: "rewritten") |> Repo.update!()
    end
  end

  test "provider attempts and deterministic evaluations become immutable evidence", %{
    fixture: fixture,
    observation: observation,
    run: run
  } do
    now = DateTime.utc_now()

    attempt =
      %ProviderAttempt{}
      |> ProviderAttempt.create_changeset(run, observation, %{
        attempt_number: 1,
        client_request_id: Ecto.UUID.generate(),
        started_at: now,
        lease_expires_at: DateTime.add(now, 900, :second)
      })
      |> Repo.insert!()
      |> ProviderAttempt.result_changeset(%{
        status: :succeeded,
        retryable: false,
        provider_request_id: "provider-request-2",
        latency_ms: 30,
        finished_at: now
      })
      |> Repo.update!()

    assert_raise Postgrex.Error, ~r/terminal provider attempt is immutable/, fn ->
      attempt |> change(provider_request_id: "different-request") |> Repo.update!()
    end

    evaluation =
      %CaptureEvaluation{}
      |> CaptureEvaluation.create_changeset(observation, fixture.contract, %{
        evaluator_engine_version: fixture.contract.evaluator_engine_version,
        contract_fingerprint: fixture.contract.contract_fingerprint,
        status: :pass,
        root_rule_id: "contract",
        evaluated_at: now
      })
      |> Repo.insert!()

    rule_result =
      %CaptureRuleResult{}
      |> CaptureRuleResult.create_changeset(evaluation, %{
        position: 0,
        rule_id: "allowed_label",
        rule_type: "classification",
        status: :pass,
        code: "allowed_classification",
        explanation: "The output matches an allowed label.",
        evidence: %{"normalized_output" => "approved"},
        child_rule_ids: []
      })
      |> Repo.insert!()

    assert_raise Postgrex.Error, ~r/capture evaluation evidence is immutable/, fn ->
      evaluation |> change(status: :fail) |> Repo.update!()
    end

    assert_raise Postgrex.Error, ~r/capture evaluation evidence is immutable/, fn ->
      rule_result |> change(code: "rewritten") |> Repo.update!()
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
