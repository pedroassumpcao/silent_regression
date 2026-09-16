defmodule SilentRegression.MonitorOperationsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Captures
  alias SilentRegression.Captures.{CaptureRun, ProviderAttempt}
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.MonitorOperations.Workers.DispatcherWorker
  alias SilentRegression.Monitors
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.PilotPolicies
  alias SilentRegression.ProviderCredentials
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo

  setup do
    scope = workspace_scope_fixture()
    fixture = approved_baseline_fixture(scope)
    %{fixture: fixture, scope: scope}
  end

  describe "owner operations" do
    test "activates an approved monitor on a UTC cadence and exposes durable state", %{
      fixture: fixture,
      scope: scope
    } do
      now = ~U[2026-09-16 15:00:00Z]

      assert {:ok, monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily}, at: now)

      assert monitor.state == :active
      assert monitor.cadence == :daily
      assert monitor.next_run_at == ~U[2026-09-17 15:00:00Z]
      assert monitor.schedule_updated_at == now
      assert monitor.schedule_updated_by_user_id == scope.user.id

      assert {:ok, state} = MonitorOperations.get_state(scope, monitor.id)
      assert state.approved_baseline?
      assert state.can_manage?
      assert state.maximum_call_count == 2
      assert state.unresolved_alerts == 0

      event =
        scope
        |> Audit.list_workspace_events()
        |> Enum.find(&(&1.action == "monitor.schedule_configured"))

      assert event.metadata["cadence"] == "daily"
      assert event.metadata["next_run_at"] == "2026-09-17T15:00:00Z"
    end

    test "requires the compatible approved baseline and an owner", %{scope: scope} do
      unapproved = baseline_ready_monitor_fixture(scope)

      assert {:error, :baseline_required} =
               MonitorOperations.configure(scope, unapproved.monitor.id, %{cadence: :manual})

      member = invite_and_accept_member(scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      assert {:ok, member_state} =
               MonitorOperations.get_state(member_scope, unapproved.monitor.id)

      refute member_state.can_manage?

      assert {:error, :owner_required} =
               MonitorOperations.configure(member_scope, unapproved.monitor.id, %{
                 cadence: :daily
               })
    end

    test "run now plans and enqueues through the shared bounded capture pipeline", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert run.kind == :manual
      assert run.status == :queued
      assert run.samples_per_case == 1
      assert run.retry_limit == 1
      assert run.maximum_call_count == 2
      assert run.baseline_snapshot_id == fixture.baseline.id
      assert String.starts_with?(run.identity_key, "manual:")

      assert [%Oban.Job{args: args}] =
               all_enqueued(worker: ObservationWorker)
               |> Enum.filter(&(&1.args["capture_run_id"] == run.id))

      assert :ok = perform_job(ObservationWorker, args)
      assert {:ok, %{status: :succeeded}} = Captures.get_run(scope, run.id)
    end

    test "pause cancels unfinished work and resume anchors a new future slot", %{
      fixture: fixture,
      scope: scope
    } do
      configured_at = ~U[2026-09-16 15:00:00Z]

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :weekly},
                 at: configured_at
               )

      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)

      assert {:ok, paused} =
               MonitorOperations.pause(scope, fixture.monitor.id, at: ~U[2026-09-17 10:00:00Z])

      assert paused.state == :paused
      assert paused.pause_reason == :owner_paused
      assert paused.next_run_at == nil
      assert {:ok, %{status: :cancelled}} = Captures.get_run(scope, run.id)

      [job] =
        all_enqueued(worker: ObservationWorker)
        |> Enum.filter(&(&1.args["capture_run_id"] == run.id))

      assert :ok = perform_job(ObservationWorker, job.args)

      refute Repo.exists?(
               from attempt in ProviderAttempt, where: attempt.capture_run_id == ^run.id
             )

      assert {:ok, resumed} =
               MonitorOperations.resume(scope, fixture.monitor.id, at: ~U[2026-09-18 10:00:00Z])

      assert resumed.state == :active
      assert resumed.pause_reason == nil
      assert resumed.next_run_at == ~U[2026-09-25 10:00:00Z]
    end
  end

  describe "dispatcher" do
    test "schedules a due window once and advances from the intended slot", %{
      fixture: fixture,
      scope: scope
    } do
      activated_at = ~U[2026-09-10 12:00:00Z]
      due_at = ~U[2026-09-11 12:00:00Z]

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily},
                 at: activated_at
               )

      assert {:ok, %{scheduled: 1}} = MonitorOperations.dispatch_due(due_at)
      assert {:ok, %{scheduled: 0}} = MonitorOperations.dispatch_due(due_at)

      assert [run] =
               Repo.all(
                 from run in CaptureRun,
                   where: run.monitor_id == ^fixture.monitor.id and run.kind == :scheduled
               )

      assert run.identity_key ==
               "scheduled:#{fixture.monitor.id}:2026-09-11T12:00:00Z"

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.last_scheduled_at == due_at
      assert monitor.next_run_at == ~U[2026-09-12 12:00:00Z]
    end

    test "an overlap is skipped atomically and advances without a second capture", %{
      fixture: fixture,
      scope: scope
    } do
      activated_at = ~U[2026-09-10 12:00:00Z]

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily},
                 at: activated_at
               )

      assert {:ok, manual} = MonitorOperations.run_now(scope, fixture.monitor.id)

      assert {:ok, %{skipped: 1}} =
               MonitorOperations.dispatch_due(~U[2026-09-13 13:00:00Z])

      assert Repo.aggregate(
               from(run in CaptureRun,
                 where:
                   run.monitor_id == ^fixture.monitor.id and run.kind in [:manual, :scheduled]
               ),
               :count
             ) == 1

      assert Repo.get!(CaptureRun, manual.id).status == :queued
      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.last_scheduled_at == ~U[2026-09-11 12:00:00Z]
      assert monitor.next_run_at == ~U[2026-09-14 12:00:00Z]
    end

    test "revoked credentials auto-pause before another provider attempt", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily},
                 at: ~U[2026-09-10 12:00:00Z]
               )

      assert {:ok, _revoked} =
               ProviderCredentials.revoke_credential(scope, fixture.credential.id)

      assert {:ok, %{paused: 1}} =
               MonitorOperations.sweep_ineligible(~U[2026-09-10 12:01:00Z])

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.state == :paused
      assert monitor.pause_reason == :credential_unavailable
      assert monitor.next_run_at == nil
    end

    test "incompatible behavior auto-pauses an active monitor", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily})

      assert {:ok, _draft} =
               Monitors.create_version(
                 scope,
                 fixture.monitor.id,
                 valid_version_attributes(%{
                   system_prompt: "Changed behavior after baseline approval."
                 })
               )

      assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.state == :paused
      assert monitor.pause_reason == :incompatible_configuration
    end

    test "two consecutive authentication failures auto-pause the monitor", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

      credential = Repo.get!(ProviderCredential, fixture.credential.id)

      credential
      |> Ecto.Changeset.change(secret: "sk-test-authentication-error")
      |> Repo.update!()

      for _attempt <- 1..2 do
        assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
        assert [job] = jobs_for_run(run.id)
        assert :ok = perform_job(ObservationWorker, job.args)
        assert {:ok, %{status: :failed}} = Captures.get_run(scope, run.id)
      end

      assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.state == :paused
      assert monitor.pause_reason == :repeated_authentication_failures
    end

    test "the workspace call envelope auto-pauses before another bounded run", %{
      fixture: fixture,
      scope: scope
    } do
      PilotPolicies.update_limits!(scope.workspace.id, %{
        daily_run_limit: 20,
        daily_call_limit: 4,
        per_run_call_limit: 4
      })

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert [job] = jobs_for_run(run.id)
      assert :ok = perform_job(ObservationWorker, job.args)

      assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.state == :paused
      assert monitor.pause_reason == :workspace_call_limit
    end

    test "the recurring worker sweeps and dispatches due monitors", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily},
                 at: DateTime.add(DateTime.utc_now(:second), -86_401, :second)
               )

      assert DateTime.before?(monitor.next_run_at, DateTime.utc_now())
      assert :ok = perform_job(DispatcherWorker, %{})

      assert Repo.exists?(
               from run in CaptureRun,
                 where: run.monitor_id == ^fixture.monitor.id and run.kind == :scheduled
             )
    end
  end

  defp jobs_for_run(run_id) do
    all_enqueued(worker: ObservationWorker)
    |> Enum.filter(&(&1.args["capture_run_id"] == run_id))
  end
end
