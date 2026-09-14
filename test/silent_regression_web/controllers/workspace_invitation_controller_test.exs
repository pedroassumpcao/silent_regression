defmodule SilentRegressionWeb.WorkspaceInvitationControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.AccountsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Invitation, Membership}

  test "GET /invitations/:token renders only safe invitation data", %{conn: conn} do
    pending =
      operator_invitation_fixture(%{
        workspace_name: "Acme AI",
        email: "owner@acme.example"
      })

    conn = get(conn, ~p"/invitations/#{pending.token}")

    assert inertia_component(conn) == "Auth/AcceptInvitation"

    assert %{
             email: "owner@acme.example",
             role: :owner,
             token: token,
             workspaceName: "Acme AI"
           } = inertia_props(conn)

    assert token == pending.token
    assert Repo.aggregate(Membership, :count) == 0
  end

  test "POST /invitations/:token atomically accepts and authenticates", %{conn: conn} do
    pending = operator_invitation_fixture(%{workspace_slug: "acme-ai"})

    conn = post(conn, ~p"/invitations/#{pending.token}")

    assert get_session(conn, :user_token)
    assert redirected_to(conn) == ~p"/app/acme-ai"
    assert Repo.aggregate(Membership, :count) == 1

    assert Repo.get!(Invitation, pending.invitation.id).status == :accepted

    second_attempt = conn |> recycle() |> post(~p"/invitations/#{pending.token}")
    assert redirected_to(second_attempt) == ~p"/users/log-in"
    assert Repo.aggregate(Membership, :count) == 1
  end

  test "invalid invitation links disclose no lifecycle detail", %{conn: conn} do
    conn = get(conn, ~p"/invitations/not-a-valid-token")

    assert html_response(conn, 410)
    assert inertia_component(conn) == "Auth/InvitationUnavailable"

    assert inertia_props(conn).message ==
             "This invitation is invalid, expired, revoked, or has already been used."
  end

  test "a logged-in user cannot accept an invitation for another identity", %{conn: conn} do
    pending = operator_invitation_fixture(%{email: "invited@example.com"})
    other_user = user_fixture(%{email: "other@example.com"})

    conn =
      conn
      |> log_in_user(other_user)
      |> get(~p"/invitations/#{pending.token}")

    assert html_response(conn, 403)
    assert inertia_component(conn) == "Auth/InvitationUnavailable"
    assert Repo.aggregate(Membership, :count) == 0
  end

  test "public registration is absent for both reads and writes", %{conn: conn} do
    assert response(get(conn, "/users/register"), 404)
    assert response(post(conn, "/users/register", %{"user" => %{"email" => "x@y.z"}}), 404)
  end
end
