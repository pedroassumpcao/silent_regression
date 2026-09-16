defmodule SilentRegressionWeb.ContractAuthoringController do
  use SilentRegressionWeb, :controller

  import Inertia.Controller, only: [assign_errors: 2]

  alias SilentRegression.ContractAuthoring
  alias SilentRegression.ContractAuthoring.{ContractVersion, FixtureJudgment}
  alias SilentRegression.Contracts.Limits
  alias SilentRegression.Reviews

  def show(conn, %{"monitor_id" => monitor_id}) do
    case ContractAuthoring.get_state(conn.assigns.current_scope, monitor_id) do
      {:ok, state} -> render_contract(conn, state)
      {:error, :setup_incomplete} -> redirect_to_setup(conn, monitor_id)
      {:error, :not_found} -> send_resp(conn, :not_found, "Not found")
    end
  end

  def save(conn, %{"monitor_id" => monitor_id} = params) do
    case ContractAuthoring.save_draft(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "contract", %{})
         ) do
      {:ok, _contract_version} ->
        conn
        |> put_flash(:info, "Contract draft saved. Validate it with known outputs next.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :update})
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :setup_incomplete} ->
        redirect_to_setup(conn, monitor_id)

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, :revision_required} ->
        mutation_failed(
          conn,
          monitor_id,
          "Create a successor draft before editing an approved contract."
        )

      {:error, _reason} ->
        mutation_failed(conn, monitor_id, "The contract draft could not be saved.")
    end
  end

  def create_fixture(conn, %{"monitor_id" => monitor_id} = params) do
    case ContractAuthoring.add_fixture(
           conn.assigns.current_scope,
           monitor_id,
           Map.get(params, "fixture", %{})
         ) do
      {:ok, _fixture} ->
        conn
        |> put_flash(:info, "Fixture saved and evaluated locally. No provider call was made.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :insert})
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        mutation_failed(conn, monitor_id, "The fixture could not be saved.")
    end
  end

  def update_fixture(
        conn,
        %{"monitor_id" => monitor_id, "fixture_id" => fixture_id} = params
      ) do
    case ContractAuthoring.update_fixture(
           conn.assigns.current_scope,
           monitor_id,
           fixture_id,
           Map.get(params, "fixture", %{})
         ) do
      {:ok, _fixture} ->
        conn
        |> put_flash(:info, "Fixture updated and re-evaluated locally.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :update})
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        mutation_failed(conn, monitor_id, "The fixture could not be updated.")
    end
  end

  def delete_fixture(conn, %{"monitor_id" => monitor_id, "fixture_id" => fixture_id}) do
    case ContractAuthoring.delete_fixture(
           conn.assigns.current_scope,
           monitor_id,
           fixture_id
         ) do
      {:ok, _fixture} ->
        conn
        |> put_flash(:info, "Fixture removed.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        mutation_failed(conn, monitor_id, "The fixture could not be removed.")
    end
  end

  def approve(conn, %{"monitor_id" => monitor_id}) do
    case ContractAuthoring.approve(conn.assigns.current_scope, monitor_id) do
      {:ok, _contract_version} ->
        conn
        |> put_flash(:info, "Contract approved and sealed with its exact fixture set.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, {:approval_blocked, blockers}} ->
        conn
        |> put_flash(:error, approval_blocked_message(blockers))
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :owner_required} ->
        conn
        |> put_flash(:error, "Only a workspace owner can approve a contract.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        mutation_failed(conn, monitor_id, "The contract could not be approved.")
    end
  end

  def revise(conn, %{"monitor_id" => monitor_id}) do
    case ContractAuthoring.create_revision(conn.assigns.current_scope, monitor_id) do
      {:ok, _contract_version} ->
        conn
        |> put_flash(:info, "Successor draft created. The approved version remains unchanged.")
        |> redirect(to: contract_path(conn, monitor_id))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        mutation_failed(conn, monitor_id, "A successor draft could not be created.")
    end
  end

  defp render_contract(conn, state) do
    conn
    |> assign(:page_title, "Deterministic contract · #{state.monitor.name}")
    |> render_inertia("Monitors/Contract", %{
      approved_contract: contract_summary_prop(state.approved_contract_version),
      can_approve: conn.assigns.current_scope.membership.role == :owner,
      contract: contract_prop(state.contract_version),
      fixtures: fixture_props(state.fixture_results),
      limits: %{
        max_fixtures: ContractAuthoring.max_fixtures(),
        max_output_bytes: Limits.output_bytes()
      },
      monitor: %{
        id: state.monitor.id,
        name: state.monitor.name,
        description: state.monitor.description,
        state: state.monitor.state,
        version: state.monitor_version.version
      },
      readiness: readiness_prop(state.readiness),
      release_stage: "Private alpha",
      rescore_summary: rescore_summary_prop(state.rescore_summary),
      revision_origins: revision_origin_props(state.contract_version),
      templates: Enum.map(ContractAuthoring.templates(), &template_prop/1)
    })
  end

  defp contract_prop(nil), do: nil

  defp contract_prop(%ContractVersion{} = contract_version) do
    Map.merge(contract_summary_prop(contract_version), %{
      assistance_mode: contract_version.assistance_mode,
      contract_fingerprint: contract_version.contract_fingerprint,
      fixture_set_fingerprint: contract_version.fixture_set_fingerprint,
      root_json: Jason.encode!(contract_version.root),
      template_key: contract_version.template_key,
      template_usage: contract_version.template_usage
    })
  end

  defp contract_summary_prop(nil), do: nil

  defp contract_summary_prop(%ContractVersion{} = contract_version) do
    %{
      approved_at: contract_version.approved_at,
      approved_by_user_id: contract_version.approved_by_user_id,
      fingerprint: contract_version.fingerprint,
      id: contract_version.id,
      predecessor_id: contract_version.predecessor_id,
      status: contract_version.status,
      version: contract_version.version
    }
  end

  defp template_prop(template) do
    %{
      key: template["key"],
      title: template["title"],
      description: template["description"],
      best_for: template["best_for"],
      limitation: template["limitation"],
      root_json: Jason.encode!(template["root"])
    }
  end

  defp fixture_props(results) do
    Enum.map(results, fn result ->
      fixture = result.fixture

      %{
        actual: ContractAuthoring.evaluation_prop(result.evaluation),
        expected_failed_rule_ids:
          FixtureJudgment.failed_rule_ids(
            %{"id" => result.evaluation.root_rule_id},
            fixture.expected_rule_statuses
          ),
        expected_rule_statuses_json: Jason.encode!(fixture.expected_rule_statuses),
        expected_status: fixture.expected_status,
        fingerprint: fixture.fingerprint,
        id: fixture.id,
        judgment_complete: result.judgment_complete?,
        matches: result.matches?,
        name: fixture.name,
        output_text: fixture.output_text,
        position: fixture.position
      }
    end)
  end

  defp readiness_prop(readiness) do
    %{
      ready: readiness.ready?,
      blockers: readiness.blockers
    }
  end

  defp rescore_summary_prop(nil), do: nil

  defp rescore_summary_prop(summary) do
    %{
      observation_count: summary.observation_count,
      pass_count: summary.pass_count,
      fail_count: summary.fail_count,
      evaluator_error_count: summary.evaluator_error_count,
      interpretation_changed: summary.interpretation_changed,
      rescored_at: summary.rescored_at,
      predecessor_contract_version_id: summary.predecessor_contract_version_id
    }
  end

  defp revision_origin_props(nil), do: []

  defp revision_origin_props(contract_version) do
    contract_version.id
    |> Reviews.list_contract_revision_origins()
    |> Enum.map(fn origin ->
      %{
        id: origin.id,
        review_decision_id: origin.review_decision_id,
        classification: origin.review_decision.classification,
        action: origin.review_decision.action,
        actor: origin.actor_user.email,
        inserted_at: origin.inserted_at
      }
    end)
  end

  defp redirect_to_setup(conn, monitor_id) do
    conn
    |> put_flash(:error, "Complete monitor setup before defining its contract.")
    |> redirect(to: setup_path(conn, monitor_id))
  end

  defp mutation_failed(conn, monitor_id, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: contract_path(conn, monitor_id))
  end

  defp approval_blocked_message([]), do: "Resolve the contract approval blockers first."

  defp approval_blocked_message([blocker | rest]) do
    suffix = if rest == [], do: "", else: " (+#{length(rest)} more)"
    "#{blocker.message}#{suffix}"
  end

  defp contract_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/contract"
  end

  defp setup_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/setup"
  end
end
