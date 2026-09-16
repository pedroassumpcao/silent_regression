defmodule SilentRegression.PilotReadinessTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.{MonitorOperations, PilotReadiness, ProductAnalytics}

  test "derives the six activation stages and regresses when monitoring is paused" do
    scope = workspace_scope_fixture()

    assert %{completed_count: 0, complete: false, monitor_id: nil} =
             PilotReadiness.onboarding(scope)

    fixture = approved_baseline_fixture(scope)

    assert %{
             completed_count: 5,
             complete: false,
             monitor_id: monitor_id,
             steps: steps
           } = PilotReadiness.onboarding(scope)

    assert monitor_id == fixture.monitor.id

    assert Enum.map(steps, &{&1.key, &1.complete}) == [
             credential: true,
             workflow: true,
             cases: true,
             contract: true,
             baseline: true,
             schedule: false
           ]

    assert {:ok, _monitor} =
             MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily})

    assert %{completed_count: 6, percent: 100, complete: true} =
             PilotReadiness.onboarding(scope)

    assert {:ok, _monitor} = MonitorOperations.pause(scope, fixture.monitor.id)

    assert %{completed_count: 5, complete: false} = PilotReadiness.onboarding(scope)
  end

  test "records only allowlisted learning properties and derives funnel evidence" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)

    assert {:ok, _monitor} =
             MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily})

    event =
      ProductAnalytics.record_founder_assistance!(
        scope,
        fixture.monitor.id,
        :contract,
        :onboarding
      )

    assert event.properties == %{"reason" => "onboarding", "stage" => "contract"}

    funnel = ProductAnalytics.activation_funnel(scope)

    assert %DateTime{} = funnel.invitation_accepted_at
    assert %DateTime{} = funnel.first_monitor_activated_at
    assert is_integer(funnel.seconds_to_first_monitor)
    assert funnel.event_counts["baseline.approved"] == 1
    assert funnel.event_counts["schedule.activated"] == 1
    assert funnel.assistance_by_stage == %{"contract" => 1}

    refute inspect(ProductAnalytics.list_events(scope)) =~ fixture.monitor.description

    assert_raise ArgumentError, ~r/invalid product event/, fn ->
      ProductAnalytics.record_founder_assistance!(
        scope,
        fixture.monitor.id,
        "contract",
        "customer said the prompt is secret"
      )
    end
  end
end
