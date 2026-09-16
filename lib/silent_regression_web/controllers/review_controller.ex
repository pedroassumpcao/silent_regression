defmodule SilentRegressionWeb.ReviewController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Reviews

  def create(conn, %{"monitor_id" => monitor_id, "run_id" => run_id} = params) do
    case Reviews.submit_review(
           conn.assigns.current_scope,
           Map.get(params, "review", %{})
         ) do
      {:ok, decision} ->
        message =
          if decision.supersedes_id,
            do: "Review judgment revised. The earlier decision remains in history.",
            else: "Review judgment recorded with its exact evidence."

        conn
        |> put_flash(:info, message)
        |> redirect(to: run_path(conn, decision.monitor_id, decision.capture_run_id))

      {:error, :stale_review} ->
        review_failed(
          conn,
          monitor_id,
          run_id,
          "This judgment changed while you were reviewing it. Inspect the current decision and try again."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        review_failed(conn, monitor_id, run_id, first_error(changeset))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        review_failed(conn, monitor_id, run_id, "The review judgment could not be recorded.")
    end
  end

  def start_contract_revision(
        conn,
        %{"monitor_id" => monitor_id, "run_id" => run_id, "review_id" => review_id}
      ) do
    case Reviews.start_contract_revision(conn.assigns.current_scope, review_id) do
      {:ok, result} ->
        conn
        |> put_flash(
          :info,
          "Successor contract draft linked to this review. Historical evidence remains unchanged."
        )
        |> redirect(to: contract_path(conn, result.contract_version.monitor_id))

      {:error, :stale_review} ->
        review_failed(
          conn,
          monitor_id,
          run_id,
          "Only the current judgment can start a contract revision."
        )

      {:error, :contract_action_required} ->
        review_failed(
          conn,
          monitor_id,
          run_id,
          "Record contract revision as the review action before starting a draft."
        )

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        review_failed(conn, monitor_id, run_id, "The successor draft could not be started.")
    end
  end

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _options} -> message end) do
      errors when map_size(errors) == 0 -> "The review judgment is invalid."
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end

  defp review_failed(conn, monitor_id, run_id, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: run_path(conn, monitor_id, run_id))
  end

  defp run_path(conn, monitor_id, run_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/runs/#{run_id}"
  end

  defp contract_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/contract"
  end
end
