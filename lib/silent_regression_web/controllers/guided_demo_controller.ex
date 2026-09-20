defmodule SilentRegressionWeb.GuidedDemoController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.{GuidedDemo, ProductAnalytics}

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    conn
    |> assign(:page_title, "Credential-free demo")
    |> render_inertia("Demo/Show", %{
      progress: ProductAnalytics.demo_progress(scope),
      release_stage: "Private alpha",
      scenario: GuidedDemo.scenario(),
      workspace: %{name: scope.workspace.name, slug: scope.workspace.slug}
    })
  end

  def start(conn, _params) do
    scope = conn.assigns.current_scope

    case ProductAnalytics.start_demo(scope) do
      {:ok, _progress} ->
        conn
        |> put_flash(:info, "Credential-free demo started. No provider call was made.")
        |> redirect(to: demo_path(scope.workspace.slug))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The demo could not be started.")
        |> redirect(to: demo_path(scope.workspace.slug))
    end
  end

  def complete_step(conn, %{"step" => step}) do
    scope = conn.assigns.current_scope

    case ProductAnalytics.complete_demo_step(scope, step) do
      {:ok, %{status: :completed}} ->
        conn
        |> put_flash(
          :info,
          "Demo completed with exact deterministic evidence and zero provider calls."
        )
        |> redirect(to: demo_path(scope.workspace.slug))

      {:ok, _progress} ->
        redirect(conn, to: demo_path(scope.workspace.slug))

      {:error, :not_started} ->
        conn
        |> put_flash(:error, "Start the demo before advancing its evidence steps.")
        |> redirect(to: demo_path(scope.workspace.slug))

      {:error, :out_of_order} ->
        conn
        |> put_flash(:error, "Complete the current demo step before advancing.")
        |> redirect(to: demo_path(scope.workspace.slug))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The demo step could not be recorded.")
        |> redirect(to: demo_path(scope.workspace.slug))
    end
  end

  defp demo_path(workspace_slug), do: ~p"/app/#{workspace_slug}/demo"
end
