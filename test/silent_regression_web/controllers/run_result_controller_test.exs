defmodule SilentRegressionWeb.RunResultControllerTest do
  use SilentRegressionWeb.ConnCase, async: false
  use Oban.Testing, repo: SilentRegression.Repo

  import Ecto.Query
  import Inertia.Testing
  import SilentRegression.ContractAuthoringFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.MonitorOperations
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.RunResults.Alert
  alias SilentRegression.WorkspacesFixtures

  setup :register_and_log_in_workspace

  test "authenticated workspace routes expose result history, evidence, and a redacted diagnostic",
       %{
         conn: conn,
         scope: scope,
         workspace: workspace
       } do
    %{fixture: fixture, run: run, alert: alert} = failed_run_fixture(scope)
    results_path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/results"
    run_path = ~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/runs/#{run.id}"

    assert redirected_to(get(build_conn(), results_path)) == ~p"/users/log-in"

    results_page = get(conn, results_path)
    assert html_response(results_page, 200)
    assert inertia_component(results_page) == "Monitors/Results"
    assert inertia_props(results_page).monitor.id == fixture.monitor.id
    assert [presented_run] = inertia_props(results_page).runs
    assert presented_run.id == run.id
    assert presented_run.criticalAlertCount == 1
    assert [presented_alert] = inertia_props(results_page).alerts
    assert presented_alert.id == alert.id
    assert presented_alert.category == :contract_failure

    run_page = results_page |> recycle() |> get(run_path)
    assert html_response(run_page, 200)
    assert inertia_component(run_page) == "Monitors/Run"
    assert inertia_props(run_page).result.summary.id == run.id
    assert inertia_props(run_page).result.provenance.compatible
    assert [observation] = inertia_props(run_page).result.observations
    assert observation.output.text == "maybe"
    assert [evaluation] = observation.evaluations
    assert evaluation.status == :fail

    diagnostic = run_page |> recycle() |> get(run_path <> "/diagnostic")
    assert response(diagnostic, 200)
    assert get_resp_header(diagnostic, "content-type") == ["application/json"]
    assert [disposition] = get_resp_header(diagnostic, "content-disposition")
    assert disposition =~ "silent-regression-run-#{run.id}-diagnostic.json"

    payload = Jason.decode!(diagnostic.resp_body)
    refute Map.has_key?(payload, "configuration")
    refute diagnostic.resp_body =~ "user_prompt_template"
    refute diagnostic.resp_body =~ "input_variables"
    refute diagnostic.resp_body =~ "output_text"
    refute diagnostic.resp_body =~ "maybe"
  end

  test "workspace alert inbox and forward-only lifecycle honor member and owner permissions", %{
    conn: owner_conn,
    scope: owner_scope,
    workspace: workspace
  } do
    %{alert: alert} = failed_run_fixture(owner_scope)
    alerts_path = ~p"/app/#{workspace.slug}/alerts"

    alert_page = get(owner_conn, alerts_path)
    assert inertia_component(alert_page) == "Alerts/Index"
    assert inertia_props(alert_page).canResolve
    assert [presented] = inertia_props(alert_page).alerts
    assert presented.id == alert.id
    assert presented.status == :open

    member = WorkspacesFixtures.invite_and_accept_member(owner_scope)
    member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
    member_conn = log_in_user(build_conn(), member.user)

    member_page = get(member_conn, alerts_path)
    refute inertia_props(member_page).canResolve

    acknowledged =
      post(recycle(member_page), ~p"/app/#{workspace.slug}/alerts/#{alert.id}/acknowledge")

    assert redirected_to(acknowledged) =~ "/runs/"
    assert Phoenix.Flash.get(acknowledged.assigns.flash, :info) =~ "acknowledged"

    denied = post(recycle(acknowledged), ~p"/app/#{workspace.slug}/alerts/#{alert.id}/resolve")
    assert redirected_to(denied) == alerts_path
    assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "Only a workspace owner"

    assert {:ok, member_alert} = SilentRegression.RunResults.get_alert(member_scope, alert.id)
    assert member_alert.status == :acknowledged

    resolved =
      alert_page
      |> recycle()
      |> post(~p"/app/#{workspace.slug}/alerts/#{alert.id}/resolve")

    assert redirected_to(resolved) =~ "/runs/"
    assert Phoenix.Flash.get(resolved.assigns.flash, :info) =~ "resolved"
    assert Repo.get!(Alert, alert.id).status == :resolved
  end

  test "malformed and foreign monitor, run, and alert identifiers stay hidden", %{
    conn: conn,
    scope: scope,
    workspace: workspace
  } do
    fixture = operational_monitor_fixture(scope)
    malformed = get(conn, ~p"/app/#{workspace.slug}/monitors/not-a-uuid/results")
    assert response(malformed, 404) == "Not found"

    other_scope = WorkspacesFixtures.workspace_scope_fixture()
    %{fixture: other, run: other_run, alert: other_alert} = failed_run_fixture(other_scope)

    foreign_results =
      malformed
      |> recycle()
      |> get(~p"/app/#{workspace.slug}/monitors/#{other.monitor.id}/results")

    assert response(foreign_results, 404) == "Not found"

    foreign_run =
      foreign_results
      |> recycle()
      |> get(~p"/app/#{workspace.slug}/monitors/#{fixture.monitor.id}/runs/#{other_run.id}")

    assert response(foreign_run, 404) == "Not found"

    foreign_alert =
      foreign_run
      |> recycle()
      |> post(~p"/app/#{workspace.slug}/alerts/#{other_alert.id}/acknowledge")

    assert response(foreign_alert, 404) == "Not found"
  end

  defp failed_run_fixture(scope) do
    fixture = operational_monitor_fixture(scope)
    replace_secret(fixture.credential.id, "sk-test-output-maybe")

    assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
    [job] = jobs_for_run(run.id)
    assert :ok = perform_job(ObservationWorker, job.args)
    alert = Repo.one!(from alert in Alert, where: alert.capture_run_id == ^run.id)

    %{
      fixture: fixture,
      run: Repo.get!(SilentRegression.Captures.CaptureRun, run.id),
      alert: alert
    }
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
end
