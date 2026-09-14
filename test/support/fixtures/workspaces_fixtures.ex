defmodule SilentRegression.WorkspacesFixtures do
  @moduledoc """
  Test helpers for invite-only workspaces and memberships.
  """

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Workspaces

  def unique_workspace_slug, do: "workspace-#{System.unique_integer([:positive])}"

  def unique_workspace_email,
    do: "workspace-user-#{System.unique_integer([:positive])}@example.com"

  def operator_invitation_fixture(attrs \\ %{}) do
    defaults = %{
      workspace_name: "Alpha Workspace",
      workspace_slug: unique_workspace_slug(),
      email: unique_workspace_email(),
      role: :owner
    }

    {:ok, result} = Workspaces.operator_create_invitation(Map.merge(defaults, attrs))
    result
  end

  def accepted_workspace_fixture(attrs \\ %{}) do
    invitation = operator_invitation_fixture(attrs)
    {:ok, accepted} = Workspaces.accept_invitation(invitation.token)
    accepted
  end

  def workspace_scope_fixture(attrs \\ %{}) do
    accepted = accepted_workspace_fixture(attrs)
    Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
  end

  def invite_and_accept_member(owner_scope, attrs \\ %{}) do
    defaults = %{email: unique_workspace_email(), role: :member}
    {:ok, invitation} = Workspaces.create_invitation(owner_scope, Map.merge(defaults, attrs))
    {:ok, accepted} = Workspaces.accept_invitation(invitation.token)
    accepted
  end
end
