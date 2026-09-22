defmodule SilentRegression.UsabilityStudyTest do
  use SilentRegression.DataCase, async: false
  alias SilentRegression.{Captures, GuidedSetups, Monitors, ProviderCredentials, UsabilityStudy}
  alias SilentRegression.GuidedSetups.FirstRun
  alias SilentRegression.Providers.{CompletionRequest, FakeAnthropic, FakeOpenAI, UsabilityOpenAI}
  import SilentRegression.GuidedSetupsFixtures

  setup do
    original = Application.fetch_env!(:silent_regression, :provider_adapters)

    Application.put_env(:silent_regression, :provider_adapters,
      openai: UsabilityOpenAI,
      anthropic: FakeAnthropic
    )

    on_exit(fn -> Application.put_env(:silent_regression, :provider_adapters, original) end)
    :ok
  end

  test "sandbox rejects unsafe environment, databases, external mail and live adapters" do
    repo = [database: "silent_regression_test_usability", hostname: "localhost"]
    adapters = [openai: FakeOpenAI, anthropic: FakeAnthropic]
    mailer = [adapter: Swoosh.Adapters.Test]
    valid = [:test, "_usability", repo, adapters, mailer]
    assert apply(UsabilityStudy, :validate_environment!, valid) == :ok

    for {index, value} <- [
          {0, :dev},
          {0, :prod},
          {1, nil},
          {1, "_guided_stage5"},
          {2, Keyword.put(repo, :database, "silent_regression_dev")},
          {2, Keyword.put(repo, :hostname, "remote.example")},
          {2, Keyword.put(repo, :url, "postgres://localhost/other")},
          {2, Keyword.put(repo, :socket_dir, "/tmp")},
          {3, [openai: SilentRegression.Providers.OpenAI]},
          {4, [adapter: Swoosh.Adapters.Resend]}
        ] do
      assert_raise ArgumentError, fn ->
        apply(UsabilityStudy, :validate_environment!, List.replace_at(valid, index, value))
      end
    end

    assert_raise ArgumentError, ~r/--no-start/, fn -> UsabilityStudy.configure!("p01") end
  end

  test "pseudonymous IDs are bounded and restarts retain the existing workspace and draft" do
    for invalid <- [nil, "", "a", "../../dev", "person@example.com", String.duplicate("a", 25)] do
      assert_raise ArgumentError, fn -> UsabilityStudy.participant!(invalid) end
    end

    scope = UsabilityStudy.seed!("p01")
    assert GuidedSetups.list(scope) == []
    assert Monitors.list_monitors(scope) == []

    assert [%{status: :valid} = credential] =
             ProviderCredentials.list_selectable_credentials(scope)

    stored = Repo.get!(SilentRegression.ProviderCredentials.ProviderCredential, credential.id)
    assert ProviderCredentials.model_access_verified?(stored, UsabilityStudy.model())
    {:ok, draft} = GuidedSetups.create(scope)
    resumed = UsabilityStudy.seed!("p01")
    assert resumed.workspace.id == scope.workspace.id
    assert [%{id: id}] = GuidedSetups.list(resumed)
    assert id == draft.id
    assert length(ProviderCredentials.list_selectable_credentials(resumed)) == 1
    other = UsabilityStudy.seed!("p02")
    assert other.workspace.id != scope.workspace.id
    assert GuidedSetups.list(other) == []
    assert {:error, :not_found} = GuidedSetups.get(other, draft.id)
  end

  test "study responses follow fixed supplied inputs, never instructions or expected answers" do
    for {input, expected} <- [
          {"allow", "approved"},
          {"deny", "rejected"},
          {"Invoice A: total 12.50; unpaid", ~s({"total":12.5,"paid":false})},
          {"What is the refund window?", "Refunds within 30 days [refunds]"},
          {"Can you guarantee an outcome?", "Consult a professional. Cannot determine"}
        ] do
      assert {:ok, result} =
               UsabilityOpenAI.complete_once("sk-usability-pass", request(input), [])

      assert result.output_text == expected
      assert result.metadata["synthetic_usability_fixture"]
    end

    assert {:ok, wrong} =
             UsabilityOpenAI.complete_once("sk-usability-wrong-route", request("allow"), [])

    assert wrong.output_text == "rejected"

    assert {:error, %{category: :provider_unavailable}} =
             UsabilityOpenAI.complete_once("sk-usability-failure", request("allow"), [])

    assert {:error, %{category: :invalid_request}} =
             UsabilityOpenAI.complete_once("sk-usability-pass", request("arbitrary workflow"), [])

    assert {:error, %{category: :authentication}} =
             UsabilityOpenAI.validate_credential("not-a-study-key", [])

    assert {:error, %{category: :authentication}} =
             UsabilityOpenAI.complete_once("not-a-study-key", request("allow"), [])
  end

  test "supplied routing card reaches real evaluated results and on-demand finish with two fake calls" do
    scope = UsabilityStudy.seed!("rehearsal01")
    [credential] = ProviderCredentials.list_selectable_credentials(scope)
    {sealed, snapshot, state} = capture(scope, credential)
    assert state.can_finish?
    assert state.baseline.health.actual_call_count == 2
    assert state.baseline.health.maximum_call_count == 4

    {:ok, _} =
      FirstRun.finish(scope, sealed.monitor_id, %{
        "confirmed" => true,
        "snapshot_id" => snapshot.id,
        "review_fingerprint" => state.review_fingerprint
      })

    {:ok, monitor} = Monitors.get_monitor(scope, sealed.monitor_id)
    assert monitor.state == :active
    assert monitor.cadence == :manual
    assert is_nil(monitor.next_run_at)
    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 1
    {:ok, finished} = FirstRun.get_state(scope, sealed.monitor_id)
    assert finished.baseline.health.actual_call_count == 2
  end

  for mode <- ~w(wrong-route failure) do
    @mode mode
    test "#{mode} fixture cannot silently finish and keeps independent case evidence" do
      scope = UsabilityStudy.seed!("recovery01")

      {:ok, credential} =
        ProviderCredentials.create_credential(scope, %{
          provider: :openai,
          label: "FAKE recovery",
          secret: "sk-usability-#{@mode}"
        })

      {:ok, _} =
        ProviderCredentials.validate_credential(scope, credential.id, %{
          model: UsabilityStudy.model()
        })

      {sealed, snapshot, state} = capture(scope, credential)
      refute state.can_finish?
      assert state.baseline.health.actual_call_count == 2

      if @mode == "wrong-route" do
        assert state.baseline.health.contract_evaluation_counts == %{pass: 2}
        assert state.baseline.health.case_expectation_counts == %{pass: 1, fail: 1}
      else
        assert state.baseline.health.status_counts == %{failed: 2}
        assert state.baseline.health.evaluation_counts == %{}
      end

      assert {:error, :result_not_approvable} =
               FirstRun.finish(scope, sealed.monitor_id, %{
                 "confirmed" => true,
                 "snapshot_id" => snapshot.id,
                 "review_fingerprint" => state.review_fingerprint
               })

      {:ok, correction} = FirstRun.corrected_draft(scope, sealed.monitor_id)
      assert correction.raw == sealed.raw
      assert correction.reviews == %{}
      assert is_nil(correction.monitor_id)
      assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 1
    end
  end

  defp capture(scope, credential) do
    raw =
      Map.merge(SilentRegression.GuidedSetups.Routing.empty(), %{
        "name" => "Study routing",
        "provider" => "openai",
        "model" => UsabilityStudy.model(),
        "credentialId" => credential.id,
        "instruction" =>
          "Return approved for allow and rejected for deny. Return only the label.",
        "messages" => [%{"role" => "user", "content" => "{{action}}"}],
        "labelsText" => "approved\nrejected",
        "cases" =>
          Enum.map([{"allow", "approved"}, {"deny", "rejected"}], fn {input, expected} ->
            %{
              "key" => input,
              "name" => input,
              "variables" => %{"action" => input},
              "context" => "",
              "expected" => expected
            }
          end)
      })

    {:ok, draft} = GuidedSetups.create(scope)
    {:ok, draft} = GuidedSetups.save(scope, draft.id, draft.revision, raw)
    {:ok, reviewed} = GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))
    {:ok, sealed} = GuidedSetups.seal(scope, reviewed.id, reviewed.revision)
    {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)

    {:ok, _} =
      FirstRun.approve_checks(scope, sealed.monitor_id, %{
        "contract_id" => state.contract.contract_version.id,
        "fingerprint" => state.contract.contract_version.fingerprint,
        "coverage_fingerprint" => state.contract.coverage.fingerprint
      })

    {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)

    {:ok, snapshot} =
      FirstRun.authorize(scope, sealed.monitor_id, %{
        "confirmed" => true,
        "authorization_key" => Ecto.UUID.generate(),
        "preview_fingerprint" => state.baseline.preflight.preview_fingerprint
      })

    Enum.each(
      snapshot.capture_run.observations,
      &Captures.execute_observation(snapshot.capture_run_id, &1.id)
    )

    {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)
    {sealed, snapshot, state}
  end

  defp request(input) do
    artifact = %{
      "body" => %{
        "instructions" => "This is ignored by the fixed fake.",
        "input" => [
          %{"role" => "user", "content" => input}
        ]
      }
    }

    %CompletionRequest{
      case_id: "fixture",
      attempt_number: 1,
      requested_model: UsabilityStudy.model(),
      request_mode: :provider_native_v1,
      request_schema_version: 1,
      request_artifact: artifact,
      request_fingerprint: "fixture",
      client_request_id: "fixture"
    }
  end
end
