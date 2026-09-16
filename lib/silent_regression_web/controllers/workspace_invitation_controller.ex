defmodule SilentRegressionWeb.WorkspaceInvitationController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Workspaces
  alias SilentRegressionWeb.{RateLimit, UserAuth}

  def show(conn, %{"token" => token}) do
    with {:ok, invitation} <- Workspaces.get_invitation_by_token(token),
         :ok <- ensure_authenticated_email_matches(conn, invitation.email) do
      conn
      |> assign(:page_title, "Accept workspace invitation")
      |> render_inertia("Auth/AcceptInvitation", %{
        email: invitation.email,
        expires_at: invitation.expires_at,
        role: invitation.role,
        token: token,
        workspace_name: invitation.workspace.name
      })
    else
      {:error, :email_mismatch} ->
        conn
        |> put_status(:forbidden)
        |> assign(:page_title, "Invitation unavailable")
        |> render_inertia("Auth/InvitationUnavailable", %{
          message: "Sign out before accepting an invitation sent to another email address."
        })

      {:error, _reason} ->
        conn
        |> put_status(:gone)
        |> assign(:page_title, "Invitation unavailable")
        |> render_inertia("Auth/InvitationUnavailable", %{
          message: "This invitation is invalid, expired, revoked, or has already been used."
        })
    end
  end

  def accept(conn, %{"token" => token}) do
    case RateLimit.check(conn, :invitation_acceptance, [token]) do
      :ok ->
        with {:ok, invitation} <- Workspaces.get_invitation_by_token(token),
             :ok <- ensure_authenticated_email_matches(conn, invitation.email),
             {:ok, result} <- Workspaces.accept_invitation(token) do
          conn
          |> put_flash(:info, "Welcome to #{result.workspace.name}.")
          |> UserAuth.log_in_user(result.user, %{}, "invitation")
        else
          {:error, :email_mismatch} ->
            conn
            |> put_flash(:error, "Sign out before accepting an invitation for another email.")
            |> redirect(to: ~p"/")

          {:error, _reason} ->
            conn
            |> put_flash(:error, "This invitation is no longer available.")
            |> redirect(to: ~p"/users/log-in")
        end

      {:error, state} ->
        RateLimit.reject(conn, state)
    end
  end

  defp ensure_authenticated_email_matches(conn, invitation_email) do
    case conn.assigns[:current_scope] do
      nil -> :ok
      %{user: %{email: user_email}} -> compare_email(user_email, invitation_email)
    end
  end

  defp compare_email(user_email, invitation_email) do
    if String.downcase(user_email) == String.downcase(invitation_email) do
      :ok
    else
      {:error, :email_mismatch}
    end
  end
end
