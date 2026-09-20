defmodule SilentRegression.OperationalHealthTest do
  use SilentRegression.DataCase, async: false

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Baselines
  alias SilentRegression.Captures.{CaptureObservation, ProviderAttempt}
  alias SilentRegression.OperationalHealth
  alias SilentRegression.Providers.RequestArtifact
  alias SilentRegression.WorkspaceLifecycle

  @now ~U[2026-09-20 12:00:00Z]

  test "reports healthy content-free controls with a fresh scheduler heartbeat" do
    assert {:ok, _heartbeat} =
             OperationalHealth.record_heartbeat(:scheduler_dispatch, :ok, at: @now)

    assert %{status: :ok, checked_at: @now, checks: checks} =
             OperationalHealth.snapshot(at: @now)

    assert Enum.map(checks, & &1.name) == [
             :queues,
             :scheduler,
             :provider_outcomes,
             :notifications,
             :purge
           ]

    assert Enum.all?(checks, &(&1.status == :ok))
  end

  test "treats an expired provider reservation as a critical unknown outcome" do
    scope = workspace_scope_fixture()
    fixture = baseline_ready_monitor_fixture(scope)
    assert {:ok, preflight} = Baselines.preflight(scope, fixture.monitor.id)

    assert {:ok, snapshot} =
             Baselines.authorize(scope, fixture.monitor.id, %{
               authorization_key: Ecto.UUID.generate(),
               samples_per_case: preflight.samples_per_case,
               preview_fingerprint: preflight.preview_fingerprint
             })

    [observation] = snapshot.capture_run.observations
    {:ok, request} = RequestArtifact.build(fixture.version, hd(fixture.version.cases))

    observation
    |> CaptureObservation.lifecycle_changeset(%{status: :running})
    |> Repo.update!()

    %ProviderAttempt{}
    |> ProviderAttempt.create_changeset(snapshot.capture_run, observation, %{
      attempt_number: 1,
      client_request_id: Ecto.UUID.generate(),
      request_mode: request.mode,
      request_schema_version: request.schema_version,
      request_fingerprint: request.fingerprint,
      request_artifact: request.artifact,
      started_at: DateTime.add(@now, -1_000, :second),
      lease_expires_at: DateTime.add(@now, -1, :second)
    })
    |> Repo.insert!()

    assert {:ok, _heartbeat} =
             OperationalHealth.record_heartbeat(:scheduler_dispatch, :ok, at: @now)

    assert %{status: :critical, checks: checks} = OperationalHealth.snapshot(at: @now)
    provider_check = Enum.find(checks, &(&1.name == :provider_outcomes))
    assert provider_check.status == :critical
    assert provider_check.measurements.expired_started_attempts == 1
  end

  test "reports missed explicit deletion SLA as critical without exposing workspace identity" do
    scope = workspace_scope_fixture()
    requested_at = DateTime.add(@now, -8, :day)

    assert {:ok, _closure} =
             WorkspaceLifecycle.close_workspace(
               scope,
               :explicit_request,
               scope.workspace.slug,
               at: requested_at
             )

    assert {:ok, _heartbeat} =
             OperationalHealth.record_heartbeat(:scheduler_dispatch, :ok, at: @now)

    assert %{status: :critical, checks: checks} = OperationalHealth.snapshot(at: @now)
    purge_check = Enum.find(checks, &(&1.name == :purge))
    assert purge_check.measurements.explicit_sla_breaches == 1
    refute inspect(purge_check) =~ scope.workspace.slug
  end
end
