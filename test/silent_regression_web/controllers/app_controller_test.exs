defmodule SilentRegressionWeb.AppControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.AccountsFixtures
  import SilentRegression.WorkspacesFixtures

  test "GET /app requires authentication", %{conn: conn} do
    conn = get(conn, ~p"/app")

    assert redirected_to(conn) == ~p"/users/log-in"
    assert get_session(conn, :user_return_to) == "/app"
  end

  test "GET /app routes an invited user to their first active workspace", %{conn: conn} do
    accepted = accepted_workspace_fixture(%{workspace_slug: "acme-ai"})

    conn = conn |> log_in_user(accepted.user) |> get(~p"/app")

    assert redirected_to(conn) == ~p"/app/#{accepted.workspace.slug}"
  end

  test "GET /app handles an authenticated identity without a workspace", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/app")

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No active workspace"
  end

  test "GET /app/:workspace_slug renders only the verified workspace scope", %{conn: conn} do
    accepted = accepted_workspace_fixture(%{workspace_name: "Acme AI", workspace_slug: "acme-ai"})

    conn =
      conn
      |> log_in_user(accepted.user)
      |> get(~p"/app/#{accepted.workspace.slug}")

    html = html_response(conn, 200)
    assert inertia_component(conn) == "Dashboard"

    assert %{
             auth: %{
               user: %{id: user_id, email: email},
               workspace: %{id: workspace_id, name: "Acme AI", slug: "acme-ai"},
               membership: %{id: membership_id, role: :owner},
               workspaces: [
                 %{
                   id: workspace_id,
                   name: "Acme AI",
                   slug: "acme-ai",
                   role: :owner,
                   current: true
                 }
               ]
             },
             activation: %{
               complete: false,
               completedCount: 0,
               monitorId: nil,
               monitorName: nil,
               percent: 0,
               steps: activation_steps,
               totalCount: 6
             },
             currentSection: "overview",
             monitors: [],
             pageTitle: "Monitors",
             releaseStage: "Private alpha",
             workspace: %{name: "Acme AI", slug: "acme-ai"}
           } = inertia_props(conn)

    assert user_id == accepted.user.id
    assert email == accepted.user.email
    assert workspace_id == accepted.workspace.id
    assert membership_id == accepted.membership.id
    assert length(activation_steps) == 6
    assert Enum.all?(activation_steps, &(&1.complete == false))
    assert hd(activation_steps).href == "/app/acme-ai/credentials"

    refute inspect(inertia_props(conn)) =~ "hashed_password"
    refute inspect(inertia_props(conn)) =~ "token_hash"

    assert ["noindex,nofollow"] =
             html
             |> LazyHTML.from_document()
             |> LazyHTML.query("meta[name='robots']")
             |> LazyHTML.attribute("content")
  end

  test "unknown and unauthorized workspace slugs return the same response", %{conn: conn} do
    first = accepted_workspace_fixture(%{workspace_slug: "first-workspace"})
    second = accepted_workspace_fixture(%{workspace_slug: "second-workspace"})
    conn = log_in_user(conn, first.user)

    unauthorized = get(conn, ~p"/app/#{second.workspace.slug}")
    unknown = build_conn() |> log_in_user(first.user) |> get(~p"/app/missing-workspace")

    assert response(unauthorized, 404) == "Not found"
    assert response(unknown, 404) == "Not found"
  end
end
