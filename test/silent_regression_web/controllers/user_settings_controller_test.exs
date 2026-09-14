defmodule SilentRegressionWeb.UserSettingsControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.AccountsFixtures

  alias SilentRegression.Accounts
  alias SilentRegression.Audit.AuditEvent
  alias SilentRegression.Repo

  setup :register_and_log_in_user

  describe "GET /users/settings" do
    test "renders account settings through Inertia", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/settings")

      assert html_response(conn, 200)
      assert inertia_component(conn) == "Auth/Settings"
      assert inertia_props(conn).email == user.email
      assert inertia_props(conn).auth.user == %{id: user.id, email: user.email}
    end

    test "redirects unauthenticated users" do
      conn = build_conn() |> get(~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "requires recent authentication", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "re-authenticate"
    end
  end

  describe "PUT /users/settings/password" do
    test "updates the password, resets the session, and records an audit event", %{
      conn: conn,
      user: user
    } do
      updated =
        put(conn, ~p"/users/settings/password", %{
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(updated) == ~p"/users/settings"
      assert get_session(updated, :user_token) != get_session(conn, :user_token)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      assert Repo.get_by!(AuditEvent, action: "user.password_updated", actor_user_id: user.id)
    end

    test "preserves errors without changing the password", %{conn: conn} do
      invalid =
        put(conn, ~p"/users/settings/password", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert redirected_to(invalid) == ~p"/users/settings"
      assert get_session(invalid, :user_token) == get_session(conn, :user_token)

      page = invalid |> recycle() |> get(~p"/users/settings")
      assert inertia_props(page).errors.password =~ "at least 12"
      assert inertia_props(page).errors.passwordConfirmation =~ "does not match"
    end
  end

  describe "PUT /users/settings/email" do
    @tag :capture_log
    test "sends a confirmation without changing the current address", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings/email", %{
          "user" => %{"email" => unique_user_email()}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.get_user_by_email(user.email)

      assert Repo.get_by!(AuditEvent,
               action: "user.email_change_requested",
               actor_user_id: user.id
             )
    end

    test "returns validation errors through shared Inertia props", %{conn: conn} do
      invalid =
        put(conn, ~p"/users/settings/email", %{
          "user" => %{"email" => "with spaces"}
        })

      assert redirected_to(invalid) == ~p"/users/settings"
      page = invalid |> recycle() |> get(~p"/users/settings")
      assert inertia_props(page).errors.email =~ "must have the @ sign"
    end
  end

  describe "GET /users/settings/confirm-email/:token" do
    setup %{user: user} do
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{token: token, email: email}
    end

    test "updates the email once and records the change", %{
      conn: conn,
      user: user,
      token: token,
      email: email
    } do
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/settings"
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)
      assert Repo.get_by!(AuditEvent, action: "user.email_changed", actor_user_id: user.id)

      reused = conn |> recycle() |> get(~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(reused) == ~p"/users/settings"
      assert Phoenix.Flash.get(reused.assigns.flash, :error) =~ "invalid or it has expired"
    end

    test "redirects unauthenticated users", %{token: token} do
      conn = build_conn() |> get(~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
