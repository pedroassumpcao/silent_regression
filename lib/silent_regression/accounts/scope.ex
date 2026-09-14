defmodule SilentRegression.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `SilentRegression.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias SilentRegression.Accounts.User
  alias SilentRegression.Workspaces.{Membership, Workspace}

  defstruct user: nil, workspace: nil, membership: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Creates a tenant scope only when the membership connects the supplied user
  and workspace.
  """
  def for_workspace(
        %User{id: user_id} = user,
        %Workspace{id: workspace_id} = workspace,
        %Membership{user_id: user_id, workspace_id: workspace_id} = membership
      ) do
    %__MODULE__{user: user, workspace: workspace, membership: membership}
  end

  def for_workspace(%User{}, %Workspace{}, %Membership{}) do
    raise ArgumentError, "membership does not belong to the supplied user and workspace"
  end
end
