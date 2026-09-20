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

  test "measures the credential-free demo without storing its request or outputs" do
    scope = workspace_scope_fixture()

    assert %{status: :not_started, completed_count: 0} =
             ProductAnalytics.demo_progress(scope)

    assert {:error, :not_started} = ProductAnalytics.complete_demo_step(scope, "request")

    assert {:ok, %{status: :in_progress, current_step: "request"}} =
             ProductAnalytics.start_demo(scope)

    assert {:error, :out_of_order} =
             ProductAnalytics.complete_demo_step(scope, "expectation")

    for step <- ~w(request expectation reference incident) do
      assert {:ok, _progress} = ProductAnalytics.complete_demo_step(scope, step)
    end

    assert {:ok, %{status: :completed}} =
             ProductAnalytics.complete_demo_step(scope, "request")

    assert %{
             status: :completed,
             completed_count: 4,
             seconds_to_expectation: seconds_to_expectation,
             seconds_to_completion: seconds_to_completion
           } = ProductAnalytics.demo_progress(scope)

    assert is_integer(seconds_to_expectation)
    assert is_integer(seconds_to_completion)

    event = ProductAnalytics.record_demo_assistance!(scope, :onboarding)
    assert event.target_type == "workspace"
    assert event.properties == %{"reason" => "onboarding", "stage" => "demo"}

    assert %{
             started_count: 1,
             completed_count: 1,
             assistance_count: 1,
             median_seconds_to_expectation: median_expectation,
             median_seconds_to_completion: median_completion,
             step_counts: %{
               "request" => 1,
               "expectation" => 1,
               "reference" => 1,
               "incident" => 1
             }
           } = ProductAnalytics.demo_funnel(scope)

    assert is_integer(median_expectation)
    assert is_integer(median_completion)

    inspected = inspect(ProductAnalytics.list_events(scope))
    refute inspected =~ "charged twice"
    refute inspected =~ "technical"
    refute inspected =~ "billing"
  end
end
