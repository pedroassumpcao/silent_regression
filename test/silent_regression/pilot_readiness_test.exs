defmodule SilentRegression.PilotReadinessTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.MonitorOperations
  alias SilentRegression.OperationalHealth
  alias SilentRegression.PilotReadiness
  alias SilentRegression.ProductAnalytics
  alias SilentRegression.Workspaces
  alias SilentRegression.Workspaces.Workspace

  @now ~U[2026-09-20 12:00:00Z]
  @base_config [
    environment: "production",
    release_sha: "abcdef123456",
    enforce_invitation_gate: true,
    invitations_enabled: false,
    drill_validity_days: 90
  ]

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

  test "requires the explicit invitation switch and every current drill" do
    assert {:ok, _heartbeat} =
             OperationalHealth.record_heartbeat(:scheduler_dispatch, :ok, at: @now)

    assert %{ready: false, invitations_enabled: false, drills_current: false} =
             PilotReadiness.status(at: @now, config: @base_config)

    config = Keyword.put(@base_config, :invitations_enabled, true)

    for kind <- PilotReadiness.required_drills() do
      assert {:ok, _drill} =
               PilotReadiness.record_drill(
                 %{
                   kind: kind,
                   outcome: :passed,
                   operator_identifier: "founder@example.com",
                   evidence_ref: "ops://2026-09-20/#{kind}",
                   performed_at: @now
                 },
                 config: config
               )
    end

    assert %{ready: true, drills_current: true, operational_health: :ok} =
             PilotReadiness.status(at: @now, config: config)

    assert :ok = PilotReadiness.authorize_invitation(at: @now, config: config)
  end

  test "release-bound drills must match the current release and later failures supersede passes" do
    config = Keyword.put(@base_config, :invitations_enabled, true)

    assert {:ok, _heartbeat} =
             OperationalHealth.record_heartbeat(:scheduler_dispatch, :ok, at: @now)

    for kind <- PilotReadiness.required_drills() do
      release_sha = if kind == :rollback, do: "previous123", else: config[:release_sha]

      assert {:ok, _drill} =
               record_drill(kind, :passed, release_sha, config, @now)
    end

    assert {:error, :operational_drills_incomplete} =
             PilotReadiness.authorize_invitation(at: @now, config: config)

    assert {:ok, _drill} = record_drill(:rollback, :passed, config[:release_sha], config, @now)

    assert {:ok, _drill} =
             record_drill(
               :incident_response,
               :failed,
               config[:release_sha],
               config,
               DateTime.add(@now, 1, :second)
             )

    assert {:error, :operational_drills_incomplete} =
             PilotReadiness.authorize_invitation(
               at: DateTime.add(@now, 1, :second),
               config: config
             )
  end

  test "operator invitation creation fails closed when production enablement is absent" do
    original = Application.fetch_env!(:silent_regression, :pilot_readiness)
    Application.put_env(:silent_regression, :pilot_readiness, @base_config)
    on_exit(fn -> Application.put_env(:silent_regression, :pilot_readiness, original) end)

    slug = unique_workspace_slug()

    assert {:error, :pilot_invitations_disabled} =
             Workspaces.operator_create_invitation(%{
               workspace_name: "Blocked Pilot",
               workspace_slug: slug,
               email: unique_workspace_email(),
               role: "owner"
             })

    assert Repo.get_by(Workspace, slug: slug) == nil
  end

  defp record_drill(kind, outcome, release_sha, config, performed_at) do
    PilotReadiness.record_drill(
      %{
        kind: kind,
        outcome: outcome,
        operator_identifier: "founder@example.com",
        evidence_ref: "ops://2026-09-20/#{kind}-#{outcome}",
        release_sha: release_sha,
        performed_at: performed_at
      },
      config: config
    )
  end
end
