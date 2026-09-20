defmodule SilentRegression.MonitorOperationsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Captures
  alias SilentRegression.Captures.{CaptureObservation, CaptureRun, ProviderAttempt}
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.MonitorOperations.AuthenticationRecovery
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

    test "a non-executable draft does not pause active monitoring", %{
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

      assert {:ok, %{eligible: 1, paused: 0}} = MonitorOperations.sweep_ineligible()

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.state == :active
      assert monitor.pause_reason == nil
      assert monitor.next_run_at
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

    test "daily run exhaustion waits until UTC reset and retries the original slot", %{
      fixture: fixture,
      scope: scope
    } do
      activated_at = ~U[2026-09-19 12:00:00Z]
      due_at = ~U[2026-09-20 12:00:00Z]
      retry_at = ~U[2026-09-21 00:00:00Z]

      PilotPolicies.update_limits!(scope.workspace.id, %{
        daily_run_limit: 2,
        daily_call_limit: 20,
        per_run_call_limit: 4
      })

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily},
                 at: activated_at
               )

      assert {:ok, run} =
               MonitorOperations.run_now(scope, fixture.monitor.id,
                 at: DateTime.add(due_at, -60, :second)
               )

      assert [job] = jobs_for_run(run.id)
      assert :ok = perform_job(ObservationWorker, job.args)

      assert {:ok, %{eligible: 1, paused: 0}} =
               MonitorOperations.sweep_ineligible(DateTime.add(due_at, -30, :second))

      assert {:ok, %{waiting: 1, paused: 0, scheduled: 0}} =
               MonitorOperations.dispatch_due(due_at)

      monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert monitor.state == :active
      assert monitor.pause_reason == nil
      assert monitor.capacity_wait_reason == :workspace_run_limit
      assert monitor.capacity_intended_at == due_at
      assert monitor.capacity_retry_at == retry_at
      assert monitor.next_run_at == retry_at
      assert monitor.coverage_interrupted_at == due_at

      assert {:ok, state} = MonitorOperations.get_state(scope, fixture.monitor.id)
      assert state.coverage.status == :waiting_capacity
      assert state.coverage.capacity_reason == :workspace_run_limit
      assert state.coverage.retry_at == retry_at
      assert state.coverage.intended_at == due_at
      assert state.coverage.overdue?
      assert state.coverage.last_successful_at

      assert {:ok, %{scheduled: 1, waiting: 0}} =
               MonitorOperations.dispatch_due(retry_at)

      recovered = Repo.get!(Monitor, fixture.monitor.id)
      assert recovered.state == :active
      assert recovered.capacity_wait_reason == nil
      assert recovered.capacity_retry_at == nil
      assert recovered.capacity_intended_at == nil
      assert recovered.coverage_interrupted_at == nil
      assert recovered.last_scheduled_at == due_at
      assert recovered.next_run_at == ~U[2026-09-21 12:00:00Z]

      scheduled =
        Repo.one!(
          from scheduled in CaptureRun,
            where: scheduled.monitor_id == ^fixture.monitor.id and scheduled.kind == :scheduled
        )

      assert scheduled.identity_key ==
               "scheduled:#{fixture.monitor.id}:2026-09-20T12:00:00Z"

      events = Audit.list_workspace_events(scope)
      assert Enum.any?(events, &(&1.action == "monitor.capacity_wait_started"))
      assert Enum.any?(events, &(&1.action == "monitor.capacity_wait_recovered"))
    end

    test "daily call exhaustion is labeled accurately and per-run overflow pauses", %{
      fixture: fixture,
      scope: scope
    } do
      activated_at = ~U[2026-09-19 12:00:00Z]
      due_at = ~U[2026-09-20 12:00:00Z]

      assert {:ok, _monitor} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :daily},
                 at: activated_at
               )

      PilotPolicies.update_limits!(scope.workspace.id, %{
        daily_run_limit: 20,
        daily_call_limit: 2,
        per_run_call_limit: 2
      })

      assert {:ok, %{waiting: 1}} = MonitorOperations.dispatch_due(due_at)
      waiting = Repo.get!(Monitor, fixture.monitor.id)
      assert waiting.state == :active
      assert waiting.capacity_wait_reason == :workspace_call_limit

      PilotPolicies.update_limits!(scope.workspace.id, %{
        daily_run_limit: 20,
        daily_call_limit: 20,
        per_run_call_limit: 1
      })

      assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible(due_at)
      paused = Repo.get!(Monitor, fixture.monitor.id)
      assert paused.state == :paused
      assert paused.pause_reason == :per_run_call_limit
      assert paused.capacity_wait_reason == nil
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

  describe "authentication breaker recovery" do
    test "validates exact access, runs one probe, and preserves evidence across resume and retrip",
         %{
           fixture: fixture,
           scope: scope
         } do
      trip_authentication_breaker(scope, fixture)
      initial_failure_run_ids = authentication_failure_run_ids(fixture.monitor.id)

      assert length(initial_failure_run_ids) == 2
      replace_secret(fixture.credential.id, "sk-test-recovery-valid")

      assert {:ok, %{recovery: recovery, run: probe}} =
               MonitorOperations.authorize_authentication_recovery(scope, fixture.monitor.id)

      assert recovery.epoch == 1
      assert recovery.provider_credential_id == fixture.credential.id
      assert recovery.requested_model == fixture.version.requested_model
      assert recovery.validation_request_id == "fake_openai_validation_request"

      assert DateTime.after?(
               recovery.credential_validated_at,
               breaker_tripped_at(fixture.monitor.id)
             )

      assert probe.kind == :authentication_probe
      assert probe.samples_per_case == 1
      assert probe.retry_limit == 0
      assert probe.planned_call_count == 1
      assert probe.maximum_call_count == 1
      assert probe.baseline_snapshot_id == fixture.baseline.id

      assert Repo.aggregate(
               from(observation in CaptureObservation,
                 where: observation.capture_run_id == ^probe.id
               ),
               :count
             ) == 1

      assert Repo.get!(Monitor, fixture.monitor.id).state == :paused
      assert [job] = jobs_for_run(probe.id)
      assert :ok = perform_job(ObservationWorker, job.args)
      assert {:ok, %{status: :succeeded}} = Captures.get_run(scope, probe.id)

      assert Repo.aggregate(
               from(attempt in ProviderAttempt, where: attempt.capture_run_id == ^probe.id),
               :count
             ) == 1

      assert {:ok, state} = MonitorOperations.get_state(scope, fixture.monitor.id)
      refute state.authentication_recovery.required?
      assert state.authentication_recovery.status == :succeeded
      assert state.authentication_recovery.capture_run_id == probe.id
      assert state.authentication_recovery.validation_call_count == 1
      assert state.authentication_recovery.maximum_call_count == 1
      assert state.last_run.id in initial_failure_run_ids

      assert {:ok, resumed} = MonitorOperations.resume(scope, fixture.monitor.id)
      assert resumed.state == :active
      assert resumed.pause_reason == nil

      replace_secret(fixture.credential.id, "sk-test-authentication-error")

      for _attempt <- 1..2 do
        assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
        assert [job] = jobs_for_run(run.id)
        assert :ok = perform_job(ObservationWorker, job.args)
      end

      assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()
      assert {:ok, retripped} = MonitorOperations.get_state(scope, fixture.monitor.id)
      assert retripped.authentication_recovery.required?
      assert retripped.authentication_recovery.status == :ready
      assert retripped.authentication_recovery.epoch == 1

      assert Repo.aggregate(
               from(run in CaptureRun,
                 where:
                   run.monitor_id == ^fixture.monitor.id and
                     run.id in ^initial_failure_run_ids
               ),
               :count
             ) == 2

      assert Repo.aggregate(
               from(recovery in AuthenticationRecovery,
                 where: recovery.monitor_id == ^fixture.monitor.id
               ),
               :count
             ) == 1
    end

    test "a failed one-call probe stays paused and a new epoch can retry", %{
      fixture: fixture,
      scope: scope
    } do
      trip_authentication_breaker(scope, fixture)
      replace_secret(fixture.credential.id, "sk-test-probe-completion-authentication-error")

      assert {:ok, %{recovery: first, run: first_probe}} =
               MonitorOperations.authorize_authentication_recovery(scope, fixture.monitor.id)

      assert first.epoch == 1
      assert [job] = jobs_for_run(first_probe.id)
      assert :ok = perform_job(ObservationWorker, job.args)
      assert {:ok, %{status: :failed}} = Captures.get_run(scope, first_probe.id)

      assert Repo.aggregate(
               from(attempt in ProviderAttempt, where: attempt.capture_run_id == ^first_probe.id),
               :count
             ) == 1

      assert {:ok, failed_state} = MonitorOperations.get_state(scope, fixture.monitor.id)
      assert failed_state.authentication_recovery.required?
      assert failed_state.authentication_recovery.status == :failed
      assert failed_state.authentication_recovery.failure_category == :authentication

      assert {:error, :repeated_authentication_failures} =
               MonitorOperations.resume(scope, fixture.monitor.id)

      replace_secret(fixture.credential.id, "sk-test-recovery-valid")

      assert {:ok, %{recovery: second, run: second_probe}} =
               MonitorOperations.authorize_authentication_recovery(scope, fixture.monitor.id)

      assert second.epoch == 2
      assert second.capture_run_id != first.capture_run_id
      assert [job] = jobs_for_run(second_probe.id)
      assert :ok = perform_job(ObservationWorker, job.args)

      assert {:ok, recovered_state} = MonitorOperations.get_state(scope, fixture.monitor.id)
      refute recovered_state.authentication_recovery.required?
      assert recovered_state.authentication_recovery.status == :succeeded

      assert Repo.aggregate(
               from(recovery in AuthenticationRecovery,
                 where: recovery.monitor_id == ^fixture.monitor.id
               ),
               :count
             ) == 2
    end

    test "only an owner can authorize recovery and unavailable recovery does not revalidate", %{
      fixture: fixture,
      scope: owner_scope
    } do
      before_validation =
        ProviderCredentials.exact_model_validation(
          Repo.get!(ProviderCredential, fixture.credential.id),
          fixture.version.requested_model
        )

      assert {:error, :authentication_recovery_unavailable} =
               MonitorOperations.authorize_authentication_recovery(
                 owner_scope,
                 fixture.monitor.id
               )

      after_validation =
        ProviderCredentials.exact_model_validation(
          Repo.get!(ProviderCredential, fixture.credential.id),
          fixture.version.requested_model
        )

      assert after_validation.validated_at == before_validation.validated_at

      trip_authentication_breaker(owner_scope, fixture)
      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      assert {:error, :owner_required} =
               MonitorOperations.authorize_authentication_recovery(
                 member_scope,
                 fixture.monitor.id
               )

      refute Repo.exists?(
               from(recovery in AuthenticationRecovery,
                 where: recovery.monitor_id == ^fixture.monitor.id
               )
             )
    end
  end

  defp jobs_for_run(run_id) do
    all_enqueued(worker: ObservationWorker)
    |> Enum.filter(&(&1.args["capture_run_id"] == run_id))
  end

  defp trip_authentication_breaker(scope, fixture) do
    assert {:ok, _monitor} =
             MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

    replace_secret(fixture.credential.id, "sk-test-authentication-error")

    for _attempt <- 1..2 do
      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert [job] = jobs_for_run(run.id)
      assert :ok = perform_job(ObservationWorker, job.args)
      assert {:ok, %{status: :failed}} = Captures.get_run(scope, run.id)
    end

    assert {:ok, %{paused: 1}} = MonitorOperations.sweep_ineligible()

    assert Repo.get!(Monitor, fixture.monitor.id).pause_reason ==
             :repeated_authentication_failures
  end

  defp replace_secret(credential_id, secret) do
    ProviderCredential
    |> Repo.get!(credential_id)
    |> Ecto.Changeset.change(secret: secret)
    |> Repo.update!()
  end

  defp authentication_failure_run_ids(monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.monitor_id == ^monitor_id and run.kind == :manual and run.status == :failed
    )
    |> select([run], run.id)
    |> Repo.all()
  end

  defp breaker_tripped_at(monitor_id) do
    CaptureRun
    |> where(
      [run],
      run.monitor_id == ^monitor_id and run.kind == :manual and run.status == :failed
    )
    |> order_by([run], desc: run.completed_at)
    |> select([run], run.completed_at)
    |> limit(1)
    |> Repo.one!()
  end
end
