defmodule SilentRegression.PilotPoliciesTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Captures
  alias SilentRegression.PilotPolicies

  test "persists approved defaults and presents conservative UTC usage" do
    scope = workspace_scope_fixture()
    fixture = approved_baseline_fixture(scope)

    usage = PilotPolicies.usage(scope)

    assert usage.daily_run_limit == 20
    assert usage.daily_call_limit == 200
    assert usage.per_run_call_limit == 200
    assert usage.runs_today == 1
    assert usage.committed_calls_today == fixture.baseline.maximum_call_count
    assert usage.remaining_runs_today == 19
    assert usage.remaining_calls_today == 200 - fixture.baseline.maximum_call_count
    assert usage.allowed_models.openai == ["gpt-5.6-luna", "gpt-5.6-sol"]

    assert usage.allowed_models.anthropic == [
             "claude-haiku-4-5-20251001",
             "claude-sonnet-5"
           ]

    assert usage.resets_at.hour == 0
    assert usage.resets_at.minute == 0
    assert usage.resets_at.time_zone == "Etc/UTC"
  end

  test "capture planning cannot bypass the persisted daily run boundary" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    usage = PilotPolicies.usage(scope)

    PilotPolicies.update_limits!(scope.workspace.id, %{
      daily_run_limit: usage.runs_today,
      daily_call_limit: 200,
      per_run_call_limit: 200
    })

    assert {:error, :workspace_run_limit} =
             Captures.plan_run(scope, fixture.monitor.id, %{
               identity_key: "manual:#{Ecto.UUID.generate()}",
               kind: :manual,
               samples_per_case: 1,
               retry_limit: 1,
               maximum_call_count: 2
             })
  end

  test "per-run and daily call limits fail before a run is inserted" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    before_usage = PilotPolicies.usage(scope)

    PilotPolicies.update_limits!(scope.workspace.id, %{
      daily_run_limit: 20,
      daily_call_limit: 200,
      per_run_call_limit: 1
    })

    assert {:error, :per_run_call_limit} =
             Captures.plan_run(scope, fixture.monitor.id, %{
               identity_key: "manual:#{Ecto.UUID.generate()}",
               kind: :manual,
               samples_per_case: 1,
               retry_limit: 1,
               maximum_call_count: 2
             })

    after_usage = PilotPolicies.usage(scope)
    assert after_usage.runs_today == before_usage.runs_today
    assert after_usage.committed_calls_today == before_usage.committed_calls_today
  end
end
