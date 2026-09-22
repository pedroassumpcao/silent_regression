defmodule SilentRegressionWeb.GuidedSetupController do
  use SilentRegressionWeb, :controller
  import Inertia.Controller, only: [assign_errors: 2]
  alias SilentRegression.{GuidedSetups, ProviderCredentials}
  alias SilentRegression.Monitors.ModelCatalog

  @steps ~w(request examples checks review)

  def new(conn, _params), do: render_inertia(conn, "Monitors/GuidedSetupStart", %{})

  def create(conn, _params) do
    case GuidedSetups.create(conn.assigns.current_scope) do
      {:ok, draft} -> redirect(conn, to: draft_path(conn, draft.id, "request"))
      _ -> send_resp(conn, :not_found, "Not found")
    end
  end

  def show(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, draft} <- GuidedSetups.get(scope, id),
         %{} = state <- GuidedSetups.state(scope, draft) do
      if draft.sealed_at do
        redirect(conn,
          to: ~p"/app/#{scope.workspace.slug}/monitors/#{draft.monitor_id}/first-run"
        )
      else
        requested = Map.get(params, "step", Atom.to_string(state.stage))

        step =
          if requested in @steps and index(requested) <= index(state.stage),
            do: requested,
            else: Atom.to_string(state.stage)

        render_inertia(conn, "Monitors/GuidedSetup", %{
          draft: %{
            id: draft.id,
            revision: draft.revision,
            raw_json: Jason.encode!(draft.raw),
            reviewed_ids: Map.keys(draft.reviews)
          },
          journey: state,
          step: step,
          credentials:
            Enum.map(
              ProviderCredentials.list_selectable_credentials(scope),
              &Map.take(&1, [:id, :provider, :label])
            ),
          models: ModelCatalog.all()
        })
      end
    else
      {:error, :stale_draft} ->
        redirect(conn, to: ~p"/app/#{scope.workspace.slug}/setup-drafts/#{id}")

      _ ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  def update(conn, %{"id" => id} = params) do
    case GuidedSetups.save(conn.assigns.current_scope, id, params["revision"], params["raw"]) do
      {:ok, draft} ->
        if params["intent"] == "exit" do
          conn
          |> put_flash(:info, "Draft saved, including unfinished inputs.")
          |> redirect(to: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors")
        else
          case GuidedSetups.state(conn.assigns.current_scope, draft) do
            %{stage: stage} ->
              target = min(index(params["step"]) + 1, index(stage))

              conn
              |> put_flash(:info, "Draft saved. No provider calls were made.")
              |> redirect(to: draft_path(conn, id, Enum.at(@steps, target)))

            {:error, :stale_draft} ->
              redirect(conn,
                to: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/setup-drafts/#{id}"
              )

            _ ->
              send_resp(conn, :not_found, "Not found")
          end
        end

      error ->
        failure(conn, id, params["step"], error)
    end
  end

  def review(conn, %{"id" => id} = params) do
    case GuidedSetups.review(
           conn.assigns.current_scope,
           id,
           params["revision"],
           params["judgments"]
         ) do
      {:ok, _} ->
        if params["intent"] == "exit" do
          conn
          |> put_flash(:info, "Proof review progress saved.")
          |> redirect(to: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors")
        else
          redirect(conn, to: draft_path(conn, id, "review"))
        end

      error ->
        failure(conn, id, "checks", error)
    end
  end

  def seal(conn, %{"id" => id} = params) do
    case GuidedSetups.seal(conn.assigns.current_scope, id, params["revision"]) do
      {:ok, draft} ->
        conn
        |> put_flash(
          :info,
          "Configuration and reviewed proof saved. An owner must still approve the checks and explicitly authorize provider calls. Scheduling is off."
        )
        |> redirect(
          to:
            ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{draft.monitor_id}/first-run"
        )

      error ->
        failure(conn, id, "review", error)
    end
  end

  defp failure(conn, _id, _step, {:error, :not_found}),
    do: send_resp(conn, :not_found, "Not found")

  defp failure(conn, id, step, {:error, reason}) do
    message =
      case reason do
        :stale_draft ->
          "Another tab or teammate saved a newer revision. Your edits were not saved. Copy anything you need, then reload the latest draft before retrying."

        :already_sealed ->
          "This configuration has already been prepared. Reload to open its review."

        :invalid_draft ->
          "Draft could not be saved. Keep within 20 examples, 20 messages, 64 KB per field and 240 KB total."

        :proof_review_required ->
          "Confirm every current proof judgment before continuing. Edited inputs require a fresh review."

        _ ->
          "This draft is not ready. Review the saved request, examples and connection before continuing."
      end

    conn
    |> assign_errors(%{draft: message})
    |> redirect(to: draft_path(conn, id, if(step in @steps, do: step, else: "request")))
  end

  defp index(step) when is_atom(step), do: index(Atom.to_string(step))
  defp index(step) when is_binary(step), do: Enum.find_index(@steps, &(&1 == step)) || 0
  defp index(_step), do: 0

  defp draft_path(conn, id, step),
    do: ~p"/app/#{conn.assigns.current_scope.workspace.slug}/setup-drafts/#{id}/#{step}"
end
