defmodule SilentRegression.RunResults.IncidentsTest do
  use SilentRegression.DataCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import Ecto.Query
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.Notifications.Delivery
  alias SilentRegression.Notifications.Workers.AlertEmailWorker
  alias SilentRegression.PilotPolicies
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Reviews
  alias SilentRegression.RunResults
  alias SilentRegression.RunResults.{Alert, Incident, IncidentOccurrence, Incidents}

  test "same signature groups across runs and synchronization remains idempotent" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    replace_secret(fixture.credential.id, "sk-test-output-maybe")

    first_run = run_monitor!(scope, fixture.monitor.id)
    second_run = run_monitor!(scope, fixture.monitor.id)

    assert [incident] = incidents_for_monitor(fixture.monitor.id)
    assert incident.signature_schema_version == "incident_signature_v1"
    assert incident.status == :open
    assert incident.occurrence_count == 2
    assert incident.run_count == 2
    assert incident.affected_case_count == 1

    assert [first, second] =
             IncidentOccurrence
             |> where([occurrence], occurrence.result_incident_id == ^incident.id)
             |> order_by([occurrence], asc: occurrence.ordinal)
             |> Repo.all()

    assert first.ordinal == 1
    assert first.capture_run_id == first_run.id
    assert second.ordinal == 2
    assert second.capture_run_id == second_run.id

    assert {:ok, %{status: :synchronized}} = RunResults.sync_run(second_run.id)
    assert Repo.get!(Incident, incident.id).occurrence_count == 2
    assert Repo.aggregate(IncidentOccurrence, :count) == 2
    assert Enum.map(Repo.all(Delivery), & &1.incident_occurrence_count) == [1]
  end

  test "material case identity splits otherwise equivalent contract failures" do
    scope = workspace_scope_fixture()

    fixture =
      operational_monitor_fixture(scope, %{
        cases: [
          case_attrs("case-a", "First deterministic case"),
          case_attrs("case-b", "Second deterministic case")
        ]
      })

    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    run = run_monitor!(scope, fixture.monitor.id)

    incidents = incidents_for_monitor(fixture.monitor.id)
    assert length(incidents) == 2
    assert incidents |> Enum.map(& &1.signature) |> Enum.uniq() |> length() == 2
    assert Enum.all?(incidents, &(&1.category == :contract_failure))
    assert Enum.all?(incidents, &(&1.occurrence_count == 1))

    assert Repo.aggregate(from(alert in Alert, where: alert.capture_run_id == ^run.id), :count) ==
             2

    assert incidents
           |> Enum.flat_map(& &1.signature_components["case_fingerprints"])
           |> Enum.uniq()
           |> length() == 2
  end

  test "members acknowledge while owner resolution pins the latest occurrence review" do
    owner_scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(owner_scope)
    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    run = run_monitor!(owner_scope, fixture.monitor.id)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    incident = incident_for_alert!(alert.id)

    assert {:error, :acknowledgement_required} = Incidents.resolve(owner_scope, incident.id)

    member = invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
    acknowledged_at = ~U[2026-09-20 16:00:00.000000Z]

    assert {:ok, acknowledged} =
             Incidents.acknowledge(member_scope, incident.id, at: acknowledged_at)

    assert acknowledged.status == :acknowledged
    assert acknowledged.acknowledged_by_user_id == member.user.id
    assert acknowledged.acknowledged_at == acknowledged_at
    assert {:error, :owner_required} = Incidents.resolve(member_scope, incident.id)
    assert {:error, :review_required} = Incidents.resolve(owner_scope, incident.id)

    assert {:ok, review} =
             Reviews.submit_review(member_scope, %{
               subject_kind: :alert,
               subject_id: alert.id,
               classification: :confirmed_regression,
               action: :prompt_change,
               rationale: "The latest occurrence is a confirmed deterministic regression."
             })

    resolved_at = ~U[2026-09-20 16:05:00.000000Z]
    assert {:ok, resolved} = Incidents.resolve(owner_scope, incident.id, at: resolved_at)
    assert resolved.status == :resolved
    assert resolved.resolved_by_user_id == owner_scope.user.id
    assert resolved.resolution_review_decision_id == review.id
    assert resolved.resolved_at == resolved_at

    assert {:ok, repeated} = Incidents.resolve(owner_scope, incident.id)
    assert repeated.resolved_at == resolved_at
    assert Repo.get!(Alert, alert.id).status == :open

    actions = owner_scope |> Audit.list_workspace_events() |> Enum.map(& &1.action)
    assert "incident.acknowledged" in actions
    assert "incident.resolved" in actions

    assert_raise Postgrex.Error, ~r/result incident identity is immutable/, fn ->
      resolved |> Ecto.Changeset.change(code: "rewritten") |> Repo.update!()
    end

    _later_run = run_monitor!(owner_scope, fixture.monitor.id)

    assert [closed_episode, reopened_episode] =
             fixture.monitor.id
             |> incidents_for_monitor()
             |> Enum.sort_by(& &1.episode)

    assert closed_episode.id == resolved.id
    assert closed_episode.status == :resolved
    assert reopened_episode.status == :open
    assert reopened_episode.episode == 2
    assert reopened_episode.reopened_from_id == resolved.id
  end

  test "a clean exact-provenance run recovers an episode and recurrence opens a linked episode" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    _failure = run_monitor!(scope, fixture.monitor.id)
    [first] = incidents_for_monitor(fixture.monitor.id)

    replace_secret(fixture.credential.id, "sk-test-output-approved")
    clean_run = run_monitor!(scope, fixture.monitor.id)
    recovered = Repo.get!(Incident, first.id)
    assert recovered.status == :recovered
    assert recovered.recovery_capture_run_id == clean_run.id
    assert recovered.recovered_at == clean_run.completed_at

    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    _recurrence = run_monitor!(scope, fixture.monitor.id)

    assert [episode_one, episode_two] =
             fixture.monitor.id
             |> incidents_for_monitor()
             |> Enum.sort_by(& &1.episode)

    assert episode_one.id == first.id
    assert episode_one.status == :recovered
    assert episode_two.status == :open
    assert episode_two.episode == 2
    assert episode_two.reopened_from_id == episode_one.id
    assert episode_two.signature == episode_one.signature
  end

  test "exceptional reviewed-reference provenance flags an occurrence without suppressing it" do
    scope = workspace_scope_fixture()
    fixture = exceptional_operational_monitor_fixture(scope)
    run = run_monitor!(scope, fixture.monitor.id)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    occurrence = Repo.get_by!(IncidentOccurrence, result_alert_id: alert.id)

    assert occurrence.exceptional_reference
    assert Repo.get!(Incident, occurrence.result_incident_id).status == :open
  end

  @tag timeout: 120_000
  test "fifty recurring failures retain every occurrence but enqueue only bounded milestones" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)

    PilotPolicies.update_limits!(scope.workspace.id, %{
      daily_run_limit: 100,
      daily_call_limit: 1_000,
      per_run_call_limit: 10
    })

    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    Enum.each(1..50, fn _index -> run_monitor!(scope, fixture.monitor.id) end)

    assert [incident] = incidents_for_monitor(fixture.monitor.id)
    assert incident.occurrence_count == 50
    assert incident.run_count == 50
    assert Repo.aggregate(IncidentOccurrence, :count) == 50
    assert Repo.aggregate(Alert, :count) == 50

    counts =
      Delivery
      |> order_by([delivery], asc: delivery.incident_occurrence_count)
      |> select([delivery], delivery.incident_occurrence_count)
      |> Repo.all()

    assert counts == [1, 5, 20, 50]
    assert length(all_enqueued(worker: AlertEmailWorker)) == 4

    assert {:ok, first_page} = Incidents.get_detail(scope, incident.id, %{"page" => "1"})
    assert length(first_page.occurrences) == 25
    assert first_page.pagination.total == 50
    assert first_page.pagination.total_pages == 2
    assert first_page.pagination.has_next

    assert {:ok, second_page} = Incidents.get_detail(scope, incident.id, %{"page" => "2"})
    assert length(second_page.occurrences) == 25
    assert second_page.pagination.has_previous
    refute second_page.pagination.has_next
    assert second_page.latest_occurrence.ordinal == 50
  end

  test "incident access and lifecycle stay inside the workspace boundary" do
    scope = workspace_scope_fixture()
    fixture = operational_monitor_fixture(scope)
    replace_secret(fixture.credential.id, "sk-test-output-maybe")
    run = run_monitor!(scope, fixture.monitor.id)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)
    incident = incident_for_alert!(alert.id)
    other_scope = workspace_scope_fixture()

    assert {:error, :not_found} = Incidents.get_detail(other_scope, incident.id)
    assert {:error, :not_found} = Incidents.acknowledge(other_scope, incident.id)
  end

  defp run_monitor!(scope, monitor_id) do
    assert {:ok, run} = MonitorOperations.run_now(scope, monitor_id)

    jobs = jobs_for_run(run.id)
    assert jobs != []
    Enum.each(jobs, fn job -> assert :ok = perform_job(ObservationWorker, job.args) end)

    Repo.get!(SilentRegression.Captures.CaptureRun, run.id)
  end

  defp exceptional_operational_monitor_fixture(scope) do
    fixture =
      baseline_ready_monitor_fixture(scope, %{
        cases: [
          %{
            case_key: "exceptional-reference",
            name: "Exceptional reference case",
            input_variables_json: ~s({"question":"Which decision applies?"}),
            frozen_context: "[fake:output=maybe] Known output retained for exceptional review.",
            status: "active"
          }
        ]
      })

    {:ok, preflight} = SilentRegression.Baselines.preflight(scope, fixture.monitor.id)

    {:ok, snapshot} =
      SilentRegression.Baselines.authorize(scope, fixture.monitor.id, %{
        authorization_key: Ecto.UUID.generate(),
        samples_per_case: preflight.samples_per_case,
        preview_fingerprint: preflight.preview_fingerprint
      })

    Enum.each(snapshot.capture_run.observations, fn observation ->
      assert :ok =
               SilentRegression.Captures.execute_observation(
                 snapshot.capture_run.id,
                 observation.id
               )
    end)

    assert {:ok, baseline} =
             SilentRegression.Baselines.approve(scope, fixture.monitor.id, %{
               approval_mode: :exceptional,
               approval_rationale:
                 "This deterministic failure is understood and explicitly accepted for reference."
             })

    assert {:ok, monitor} =
             MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

    Map.merge(fixture, %{baseline: baseline, monitor: monitor})
  end

  defp incidents_for_monitor(monitor_id) do
    Incident
    |> where([incident], incident.monitor_id == ^monitor_id)
    |> order_by([incident], asc: incident.inserted_at, asc: incident.id)
    |> Repo.all()
  end

  defp incident_for_alert!(alert_id) do
    occurrence = Repo.get_by!(IncidentOccurrence, result_alert_id: alert_id)
    Repo.get!(Incident, occurrence.result_incident_id)
  end

  defp jobs_for_run(run_id) do
    all_enqueued(worker: ObservationWorker)
    |> Enum.filter(&(&1.args["capture_run_id"] == run_id))
  end

  defp replace_secret(credential_id, secret) do
    ProviderCredential
    |> Repo.get!(credential_id)
    |> Ecto.Changeset.change(secret: secret)
    |> Repo.update!()
  end

  defp case_attrs(key, name) do
    %{
      case_key: key,
      name: name,
      input_variables_json: ~s({"question":"Which decision applies?"}),
      frozen_context: "Use the configured decision label.",
      status: "active"
    }
  end
end
