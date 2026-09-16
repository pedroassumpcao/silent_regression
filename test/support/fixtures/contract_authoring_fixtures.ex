defmodule SilentRegression.ContractAuthoringFixtures do
  @moduledoc """
  Test helpers for deterministic contract authoring and fixture approval.
  """

  import Ecto.Query

  alias SilentRegression.{Baselines, Captures, ContractAuthoring}
  alias SilentRegression.ContractAuthoring.Templates
  alias SilentRegression.Monitors
  alias SilentRegression.MonitorOperations
  alias SilentRegression.MonitorSetupsFixtures
  alias SilentRegression.ProviderCredentials

  def contract_ready_monitor_fixture(scope, attrs \\ %{}) do
    MonitorSetupsFixtures.complete_setup_fixture(scope, attrs)
  end

  def draft_fixture(scope, monitor, attrs \\ %{}) do
    {:ok, template} = Templates.fetch("classification")

    defaults = %{
      template_key: "classification",
      assistance_mode: "self_serve",
      root: template["root"]
    }

    {:ok, draft} = ContractAuthoring.save_draft(scope, monitor.id, Map.merge(defaults, attrs))
    draft
  end

  def fixture(scope, monitor, attrs \\ %{}) do
    defaults = %{
      name: "Known-valid output",
      output_text: "approved",
      expected_status: "pass",
      expected_failed_rule_ids: []
    }

    {:ok, fixture} = ContractAuthoring.add_fixture(scope, monitor.id, Map.merge(defaults, attrs))
    fixture
  end

  def approved_contract_fixture(scope, attrs \\ %{}) do
    completed = contract_ready_monitor_fixture(scope, attrs)
    draft = draft_fixture(scope, completed.monitor)

    _valid = fixture(scope, completed.monitor)

    _invalid =
      fixture(scope, completed.monitor, %{
        name: "Known-invalid output",
        output_text: "maybe",
        expected_status: "fail",
        expected_failed_rule_ids: ["allowed_label"]
      })

    {:ok, approved} = ContractAuthoring.approve(scope, completed.monitor.id)

    Map.merge(completed, %{draft: draft, contract: approved})
  end

  def baseline_ready_monitor_fixture(scope, attrs \\ %{}) do
    fixture = approved_contract_fixture(scope, attrs)

    {:ok, _credential} =
      ProviderCredentials.validate_credential(scope, fixture.credential.id, %{
        model: fixture.version.requested_model
      })

    {:ok, monitor} =
      Monitors.prepare_baseline(scope, fixture.monitor.id, fixture.version.id)

    %{fixture | monitor: monitor}
  end

  def approved_baseline_fixture(scope, attrs \\ %{}) do
    fixture = baseline_ready_monitor_fixture(scope, attrs)
    {:ok, preflight} = Baselines.preflight(scope, fixture.monitor.id)

    {:ok, snapshot} =
      Baselines.authorize(scope, fixture.monitor.id, %{
        authorization_key: Ecto.UUID.generate(),
        samples_per_case: preflight.samples_per_case,
        preview_fingerprint: preflight.preview_fingerprint
      })

    Enum.each(snapshot.capture_run.observations, fn observation ->
      :ok = Captures.execute_observation(snapshot.capture_run.id, observation.id)
    end)

    Oban.Job
    |> where([job], fragment("?->>'capture_run_id' = ?", job.args, ^snapshot.capture_run.id))
    |> SilentRegression.Repo.delete_all()

    {:ok, approved} =
      Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

    Map.merge(fixture, %{baseline: approved})
  end

  def operational_monitor_fixture(scope, attrs \\ %{}) do
    fixture = approved_baseline_fixture(scope, attrs)
    {:ok, monitor} = MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})
    %{fixture | monitor: monitor}
  end
end
