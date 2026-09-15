defmodule SilentRegression.ContractAuthoringFixtures do
  @moduledoc """
  Test helpers for deterministic contract authoring and fixture approval.
  """

  alias SilentRegression.ContractAuthoring
  alias SilentRegression.ContractAuthoring.Templates
  alias SilentRegression.MonitorSetupsFixtures

  def contract_ready_monitor_fixture(scope) do
    MonitorSetupsFixtures.complete_setup_fixture(scope)
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

  def approved_contract_fixture(scope) do
    completed = contract_ready_monitor_fixture(scope)
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
end
