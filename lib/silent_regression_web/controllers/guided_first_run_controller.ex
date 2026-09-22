defmodule SilentRegressionWeb.GuidedFirstRunController do
  use SilentRegressionWeb, :controller
  alias SilentRegression.GuidedSetups.FirstRun
  alias SilentRegressionWeb.RateLimit

  def show(conn, %{"monitor_id" => id}) do
    case FirstRun.get_state(conn.assigns.current_scope, id) do
      {:ok, state} -> render_inertia(conn, "Monitors/GuidedFirstRun", props(state))
      _ -> send_resp(conn, :not_found, "Not found")
    end
  end

  def approve_checks(conn, %{"monitor_id" => id} = params),
    do:
      decide(
        conn,
        id,
        FirstRun.approve_checks(conn.assigns.current_scope, id, params["identity"]),
        "Checks approved. Review the first-run limits next."
      )

  def correct(conn, %{"monitor_id" => id}) do
    case FirstRun.corrected_draft(conn.assigns.current_scope, id) do
      {:ok, draft} ->
        conn
        |> put_flash(
          :info,
          "New correction draft created. Earlier evidence is unchanged. Edit the source of truth and review all proof again; this will create a separate monitor."
        )
        |> redirect(
          to:
            ~p"/app/#{conn.assigns.current_scope.workspace.slug}/setup-drafts/#{draft.id}/request"
        )

      _ ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def validate_model(conn, %{"monitor_id" => id}) do
    rate_limited(conn, id, :credential_validation, fn ->
      decide(
        conn,
        id,
        FirstRun.validate_model(conn.assigns.current_scope, id),
        "Exact model access verified. No completion call was made."
      )
    end)
  end

  def authorize(conn, %{"monitor_id" => id} = params) do
    rate_limited(conn, id, :run_authorization, fn ->
      decide(
        conn,
        id,
        FirstRun.authorize(conn.assigns.current_scope, id, params),
        "First run authorized. This page resumes the same capture after refresh."
      )
    end)
  end

  def review(conn, %{"monitor_id" => id} = params),
    do:
      decide(
        conn,
        id,
        FirstRun.review(conn.assigns.current_scope, id, params),
        "Result review recorded. No reference was approved and no calls were made."
      )

  def finish(conn, %{"monitor_id" => id} = params),
    do:
      decide(
        conn,
        id,
        FirstRun.finish(conn.assigns.current_scope, id, params),
        "Setup complete. Your reviewed reference is approved; scheduling is off."
      )

  def reject(conn, %{"monitor_id" => id} = params),
    do:
      decide(
        conn,
        id,
        FirstRun.reject(conn.assigns.current_scope, id, params),
        "Capture rejected; evidence is retained in history. Review the limits before authorizing another attempt."
      )

  defp rate_limited(conn, id, bucket, fun) do
    scope = conn.assigns.current_scope

    case RateLimit.check(conn, bucket, [scope.workspace.id, scope.user.id, id]) do
      :ok -> fun.()
      {:error, state} -> RateLimit.reject(conn, state)
    end
  end

  defp decide(conn, _id, {:error, :not_found}, _message),
    do: send_resp(conn, :not_found, "Not found")

  defp decide(conn, id, result, message) do
    conn =
      case result do
        {:ok, _} -> put_flash(conn, :info, message)
        {:error, reason} -> put_flash(conn, :error, error_message(reason))
      end

    redirect(conn,
      to: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{id}/first-run"
    )
  end

  defp error_message(:owner_required),
    do:
      "A workspace owner must approve checks, authorize calls and finish setup. Share this page with your owner."

  defp error_message(:stale_review),
    do:
      "The result or checks changed, or review was not confirmed. Read the refreshed evidence and confirm it before trying again."

  defp error_message(:stale_preflight),
    do: "The run preview changed. Review the refreshed limits before authorizing."

  defp error_message(:authorization_required),
    do: "Explicitly confirm the displayed provider-call limits before authorizing."

  defp error_message(:advanced_configuration),
    do:
      "This configuration changed outside guided setup. Use the advanced checks and reference review to continue safely."

  defp error_message(:result_not_approvable),
    do:
      "This result cannot become a normal reference. Review failed checks, incomplete outputs, model identity and configuration compatibility."

  defp error_message({_, [%{message: message} | _]}), do: message

  defp error_message(reason)
       when reason in [:workspace_call_limit, :workspace_run_limit, :per_run_call_limit],
       do:
         "The workspace call or run limit prevents this action. Review usage in monitor operations and try again when capacity is available."

  defp error_message(_),
    do:
      "The action could not be completed. Check the connection, exact model access and current configuration in the advanced review. No additional run was authorized by this error."

  defp props(state) do
    preflight = state.baseline.preflight
    contract = state.contract.contract_version
    snapshot = state.baseline.snapshot
    health = state.baseline.health

    %{
      monitor: Map.take(state.contract.monitor, [:id, :name, :state, :cadence]),
      recipe: state.draft.recipe,
      original: state.original?,
      completed: state.completed? == true,
      can_finish: state.can_finish? == true,
      reviewed: state.reviewed?,
      review_fingerprint: state.review_fingerprint,
      authorization_key: Ecto.UUID.generate(),
      checks: %{
        approved: contract.status == :approved,
        ready: state.contract.readiness.ready?,
        identity: %{
          contract_id: contract.id,
          fingerprint: contract.fingerprint,
          coverage_fingerprint: state.contract.coverage.fingerprint
        },
        root_json: Jason.encode!(contract.root, pretty: true),
        proof: state.compiled.proof,
        fixtures:
          Enum.map(
            state.contract.fixtures,
            &Map.take(&1, [:name, :output_text, :expected_status])
          )
      },
      preflight:
        Map.take(preflight, [
          :blockers,
          :planned_call_count,
          :maximum_call_count,
          :retry_limit,
          :max_output_tokens_per_call,
          :maximum_output_tokens,
          :preview_fingerprint
        ])
        |> Map.merge(%{
          ready: preflight.ready?,
          provider: preflight.monitor_version.provider,
          model: preflight.monitor_version.requested_model,
          credential_label: preflight.credential && preflight.credential.label
        }),
      requests: state.compiled.requests,
      snapshot:
        snapshot &&
          %{
            id: snapshot.id,
            status: snapshot.status,
            run_id: snapshot.capture_run_id,
            run_status: snapshot.capture_run.status,
            terminal: health.terminal?,
            actual_calls: health.actual_call_count,
            input_tokens: health.input_tokens,
            output_tokens: health.output_tokens,
            compatible: state.baseline.compatibility.compatible?,
            blockers: health.operational_blockers,
            observations:
              Enum.sort_by(
                snapshot.capture_run.observations,
                &{&1.case_version.position, &1.sample_index}
              )
              |> Enum.map(&observation(&1, snapshot))
          }
    }
  end

  defp observation(observation, snapshot) do
    evaluation =
      Enum.find(
        observation.evaluations,
        &(&1.contract_version_id == snapshot.contract_version_id and
            &1.evaluator_engine_version == snapshot.evaluator_engine_version)
      )

    expected = SilentRegression.GuidedSetups.Recipes.summary(observation.case_version.expectation)

    checks =
      if evaluation,
        do: Map.get(evaluation.case_expectation_results || %{}, "checks", []),
        else: []

    reasons =
      if evaluation,
        do:
          Enum.map(evaluation.rule_results, & &1.explanation) ++
            Enum.map(checks, & &1["explanation"]),
        else: []

    %{
      id: observation.id,
      name: observation.case_version.name,
      input_json: Jason.encode!(observation.case_version.input_variables, pretty: true),
      context: observation.case_version.frozen_context,
      expected: expected,
      output: observation.output_text,
      status: observation.status,
      completion: observation.completion_state,
      shared: evaluation && evaluation.contract_status,
      specific: evaluation && evaluation.case_expectation_status,
      reasons: reasons,
      failure: observation.failure_message,
      request_fingerprint: observation.request_fingerprint
    }
  end
end
