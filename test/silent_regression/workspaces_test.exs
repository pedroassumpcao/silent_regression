defmodule SilentRegression.WorkspacesTest do
  use SilentRegression.DataCase, async: true

  import SilentRegression.AccountsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces
  alias SilentRegression.Workspaces.{Invitation, Membership, Workspace}

  describe "operator_create_invitation/1" do
    test "creates a workspace, hashed invitation, and audit evidence" do
      result = operator_invitation_fixture(%{email: "  OWNER@EXAMPLE.COM  "})

      assert result.workspace.status == :active
      assert result.workspace.alpha_access
      assert result.invitation.email == "owner@example.com"
      assert result.invitation.role == :owner
      assert result.invitation.status == :pending
      assert is_binary(result.token)

      stored = Repo.get!(Invitation, result.invitation.id)
      refute stored.token_hash == result.token
      refute stored.token_hash == Base.url_decode64!(result.token, padding: false)

      scope = accept_and_scope(result.token)

      assert Audit.list_workspace_events(scope)
             |> Enum.map(& &1.action)
             |> MapSet.new() ==
               MapSet.new([
                 "membership.created",
                 "invitation.accepted",
                 "invitation.created",
                 "workspace.created"
               ])
    end

    test "requires an owner invitation when creating a workspace" do
      attrs = %{
        workspace_name: "Missing Workspace",
        workspace_slug: unique_workspace_slug(),
        email: unique_workspace_email(),
        role: :member
      }

      assert {:error, :workspace_not_found} = Workspaces.operator_create_invitation(attrs)
      assert Repo.aggregate(Workspace, :count) == 0
    end

    test "rejects unsupported roles and validity windows" do
      attrs = %{
        workspace_name: "Bounded Workspace",
        workspace_slug: unique_workspace_slug(),
        email: unique_workspace_email()
      }

      assert {:error, :invalid_role} =
               Workspaces.operator_create_invitation(Map.put(attrs, :role, "admin"))

      assert {:error, :invalid_validity_days} =
               Workspaces.operator_create_invitation(Map.put(attrs, :validity_days, 31))
    end
  end

  describe "accept_invitation/1" do
    test "creates a confirmed user and membership exactly once" do
      pending = operator_invitation_fixture()

      assert {:ok, accepted} = Workspaces.accept_invitation(pending.token)
      assert accepted.user.confirmed_at
      assert accepted.membership.role == :owner
      assert accepted.membership.user_id == accepted.user.id
      assert accepted.membership.workspace_id == accepted.workspace.id
      assert accepted.invitation.status == :accepted
      assert accepted.invitation.accepted_by_user_id == accepted.user.id

      assert {:error, :accepted} = Workspaces.accept_invitation(pending.token)
      assert Repo.aggregate(Membership, :count) == 1
    end

    test "connects an existing confirmed identity to another workspace" do
      existing_user = user_fixture()

      pending =
        operator_invitation_fixture(%{
          email: String.upcase(existing_user.email),
          workspace_slug: unique_workspace_slug()
        })

      assert {:ok, accepted} = Workspaces.accept_invitation(pending.token)
      assert accepted.user.id == existing_user.id
      assert accepted.membership.user_id == existing_user.id
    end

    test "rejects expired and malformed tokens" do
      pending = operator_invitation_fixture()

      pending.invitation
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
      |> Repo.update!()

      assert {:error, :expired} = Workspaces.get_invitation_by_token(pending.token)
      assert {:error, :expired} = Workspaces.accept_invitation(pending.token)
      assert {:error, :invalid} = Workspaces.accept_invitation("not-a-token")
      assert Repo.aggregate(Membership, :count) == 0
    end
  end

  describe "workspace-owned invitation operations" do
    setup do
      accepted = accepted_workspace_fixture()
      owner_scope = Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
      %{accepted: accepted, owner_scope: owner_scope}
    end

    test "owners can invite and revoke while members cannot", %{owner_scope: owner_scope} do
      assert {:ok, pending} =
               Workspaces.create_invitation(owner_scope, %{
                 email: unique_workspace_email(),
                 role: :member
               })

      assert {:ok, revoked} = Workspaces.revoke_invitation(owner_scope, pending.invitation.id)
      assert revoked.status == :revoked
      assert {:error, :revoked} = Workspaces.accept_invitation(pending.token)

      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      assert {:error, :owner_required} =
               Workspaces.create_invitation(member_scope, %{
                 email: unique_workspace_email(),
                 role: :member
               })

      assert {:error, :owner_required} =
               Workspaces.revoke_invitation(member_scope, pending.invitation.id)

      assert {:error, :owner_required} = Workspaces.list_invitations(member_scope)
    end

    test "duplicate pending invitations are rejected without exposing another token", %{
      owner_scope: owner_scope
    } do
      email = unique_workspace_email()
      assert {:ok, _pending} = Workspaces.create_invitation(owner_scope, %{email: email})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Workspaces.create_invitation(owner_scope, %{email: String.upcase(email)})

      assert "already has a pending invitation to this workspace" in errors_on(changeset).email
    end
  end

  describe "tenant scope" do
    test "resolves only memberships belonging to the authenticated user" do
      first = accepted_workspace_fixture(%{workspace_name: "First"})
      second = accepted_workspace_fixture(%{workspace_name: "Second"})
      first_scope = Scope.for_user(first.user)

      assert {:ok, scoped} = Workspaces.scope_for_slug(first_scope, first.workspace.slug)
      assert scoped.workspace.id == first.workspace.id
      assert scoped.membership.user_id == first.user.id

      assert {:error, :not_found} =
               Workspaces.scope_for_slug(first_scope, second.workspace.slug)

      assert [{workspace, membership}] = Workspaces.list_user_workspaces(first_scope)
      assert workspace.id == first.workspace.id
      assert membership.workspace_id == first.workspace.id
    end

    test "rejects a membership combined with the wrong user or workspace" do
      first = accepted_workspace_fixture()
      second = accepted_workspace_fixture()

      assert_raise ArgumentError, fn ->
        Scope.for_workspace(first.user, second.workspace, first.membership)
      end
    end
  end

  test "role and status sets remain intentionally small" do
    assert Membership.roles() == [:owner, :member]
    assert Invitation.roles() == [:owner, :member]
    assert Invitation.statuses() == [:pending, :accepted, :revoked, :expired]
  end

  defp accept_and_scope(token) do
    {:ok, accepted} = Workspaces.accept_invitation(token)
    Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
  end
end
