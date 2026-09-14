defmodule SilentRegressionWeb.UserSessionController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Accounts
  alias SilentRegression.Audit
  alias SilentRegressionWeb.UserAuth

  def new(conn, _params) do
    email = get_in(conn.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    conn
    |> assign(:page_title, "Log in")
    |> render_inertia("Auth/Login", %{email: email || "", auth_error: nil})
  end

  # magic link login
  def create(conn, %{"user" => %{"token" => token} = user_params} = params) do
    info =
      case params do
        %{"_action" => "confirmed"} -> "User confirmed successfully."
        _ -> "Welcome back!"
      end

    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params, "magic_link")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, user_params)
    else
      Audit.record_event!(%{
        action: "user.login_failed",
        target_type: "user",
        metadata: %{"method" => "password"}
      })

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_status(:unprocessable_entity)
      |> assign(:page_title, "Log in")
      |> render_inertia("Auth/Login", %{
        email: user_params["email"] || "",
        auth_error: "Invalid email or password"
      })
    end
  end

  # magic link request
  def create(conn, %{"user" => %{"email" => email}}) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )

      Audit.record_event!(%{
        action: "user.login_link_requested",
        target_type: "user",
        target_id: user.id,
        actor_user_id: user.id,
        metadata: %{}
      })
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    conn
    |> put_flash(:info, info)
    |> redirect(to: ~p"/users/log-in")
  end

  def confirm(conn, %{"token" => token}) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      conn
      |> assign(:page_title, "Confirm login")
      |> render_inertia("Auth/ConfirmLogin", %{email: user.email, token: token})
    else
      conn
      |> put_flash(:error, "Magic link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
