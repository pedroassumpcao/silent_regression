defmodule SilentRegressionWeb.UserSettingsController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Accounts
  alias SilentRegression.Audit
  alias SilentRegressionWeb.UserAuth

  import SilentRegressionWeb.UserAuth, only: [require_sudo_mode: 2]
  import Inertia.Controller, only: [assign_errors: 2]

  plug :require_sudo_mode

  def edit(conn, _params) do
    conn
    |> assign(:page_title, "Account settings")
    |> render_inertia("Auth/Settings", %{email: conn.assigns.current_scope.user.email})
  end

  def update_email(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        Audit.record_event!(%{
          action: "user.email_change_requested",
          target_type: "user",
          target_id: user.id,
          actor_user_id: user.id,
          metadata: %{}
        })

        conn
        |> put_flash(
          :info,
          "A link to confirm your email change has been sent to the new address."
        )
        |> redirect(to: ~p"/users/settings")

      changeset ->
        conn
        |> assign_errors(%{changeset | action: :insert})
        |> redirect(to: ~p"/users/settings")
    end
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, _}} ->
        Audit.record_event!(%{
          action: "user.password_updated",
          target_type: "user",
          target_id: user.id,
          actor_user_id: user.id,
          metadata: %{}
        })

        conn
        |> put_flash(:info, "Password updated successfully.")
        |> put_session(:user_return_to, ~p"/users/settings")
        |> UserAuth.log_in_user(user, %{}, "password_change")

      {:error, changeset} ->
        conn
        |> assign_errors(changeset)
        |> redirect(to: ~p"/users/settings")
    end
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        user = conn.assigns.current_scope.user

        Audit.record_event!(%{
          action: "user.email_changed",
          target_type: "user",
          target_id: user.id,
          actor_user_id: user.id,
          metadata: %{}
        })

        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, _} ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/users/settings")
    end
  end
end
