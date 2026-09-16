defmodule SilentRegressionWeb.UserSessionControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.AccountsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts
  alias SilentRegression.Audit.AuditEvent
  alias SilentRegression.Repo

  test "router exposes neither public registration nor billing", %{conn: conn} do
    paths = Enum.map(SilentRegressionWeb.Router.__routes__(), & &1.path)

    refute Enum.any?(paths, &String.contains?(&1, "register"))
    refute Enum.any?(paths, &String.contains?(&1, "billing"))
    refute Enum.any?(paths, &String.contains?(&1, "checkout"))

    assert get(conn, "/users/register").status == 404
  end

  describe "GET /users/log-in" do
    test "renders the Inertia login page without registration", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in")

      assert html_response(conn, 200)
      assert inertia_component(conn) == "Auth/Login"
      assert %{email: "", authError: nil, auth: %{user: nil}} = inertia_props(conn)
      refute html_response(conn, 200) =~ "/users/register"
    end

    test "prefills the current identity during sudo reauthentication", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_user(user) |> get(~p"/users/log-in")

      assert inertia_props(conn).email == user.email
    end
  end

  describe "password login" do
    test "authenticates an invited workspace user and records the method", %{conn: conn} do
      accepted = accepted_workspace_fixture(%{workspace_slug: "acme-ai"})
      user = set_password(accepted.user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert get_session(conn, :user_token)
      assert conn.resp_cookies["_silent_regression_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/app/acme-ai"

      event = Repo.get_by!(AuditEvent, action: "user.logged_in", actor_user_id: user.id)
      assert event.metadata == %{"method" => "password"}
    end

    test "returns the same error for invalid credentials and records no email", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => "missing@example.com", "password" => "invalid_password"}
        })

      assert html_response(conn, 422)
      assert inertia_component(conn) == "Auth/Login"
      assert inertia_props(conn).authError == "Invalid email or password"

      event = Repo.get_by!(AuditEvent, action: "user.login_failed")
      assert event.actor_user_id == nil
      assert event.target_id == nil
      assert event.metadata == %{"method" => "password"}
    end

    test "honors a safe return path stored by the authentication plug", %{conn: conn} do
      accepted = accepted_workspace_fixture()
      user = set_password(accepted.user)

      conn =
        conn
        |> init_test_session(user_return_to: "/users/settings")
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      refute get_session(conn, :user_return_to)
    end
  end

  describe "magic-link login" do
    test "uses the same response whether or not an identity exists", %{conn: conn} do
      user = user_fixture()

      existing = post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email}})

      missing =
        conn
        |> recycle()
        |> post(~p"/users/log-in", %{"user" => %{"email" => "missing@example.com"}})

      assert redirected_to(existing) == ~p"/users/log-in"
      assert redirected_to(missing) == ~p"/users/log-in"

      assert Phoenix.Flash.get(existing.assigns.flash, :info) ==
               Phoenix.Flash.get(missing.assigns.flash, :info)

      assert Repo.get_by!(Accounts.UserToken, user_id: user.id).context == "login"
    end

    test "throttling is generic and includes a retry boundary", %{conn: conn} do
      email = "rate-limit@example.com"

      conn =
        Enum.reduce(1..10, conn, fn _attempt, conn ->
          response =
            post(recycle(conn), ~p"/users/log-in", %{"user" => %{"email" => email}})

          assert redirected_to(response) == ~p"/users/log-in"
          response
        end)

      limited = post(recycle(conn), ~p"/users/log-in", %{"user" => %{"email" => email}})

      assert response(limited, 429) == "Too many attempts. Try again later."
      assert [retry_after] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry_after) > 0
      refute response(limited, 429) =~ email
    end

    test "renders a confirmation and consumes a valid token once", %{conn: conn} do
      accepted = accepted_workspace_fixture(%{workspace_slug: "magic-workspace"})
      {token, _hashed_token} = generate_user_magic_link_token(accepted.user)

      confirmation = get(conn, ~p"/users/log-in/#{token}")
      assert inertia_component(confirmation) == "Auth/ConfirmLogin"
      assert inertia_props(confirmation).email == accepted.user.email

      logged_in = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})
      assert get_session(logged_in, :user_token)
      assert redirected_to(logged_in) == ~p"/app/magic-workspace"

      reused = conn |> recycle() |> post(~p"/users/log-in", %{"user" => %{"token" => token}})
      assert redirected_to(reused) == ~p"/users/log-in"
    end

    test "rejects an invalid token", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in/invalid-token")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or it has expired"
    end
  end

  describe "DELETE /users/log-out" do
    test "clears the session and records logout", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Repo.get_by!(AuditEvent, action: "user.logged_out", actor_user_id: user.id)
    end

    test "remains safe when already logged out", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
    end
  end
end
