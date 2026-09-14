defmodule SilentRegression.Workspaces do
  @moduledoc """
  Invite-only workspace access and tenant-scoped membership operations.

  User-facing operations require an `Accounts.Scope`. The deliberately named
  operator entry point is reserved for the local invitation Mix task.
  """

  import Ecto.Query

  alias SilentRegression.Accounts
  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Invitation, Membership, Workspace}

  @hash_algorithm :sha256
  @token_bytes 32
  @default_validity_days 7
  @maximum_validity_days 30

  def operator_create_invitation(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, role} <- normalize_role(value(attrs, :role, :owner)),
           {:ok, validity_days} <- normalize_validity_days(value(attrs, :validity_days, nil)),
           {:ok, {workspace, workspace_created?}} <- operator_workspace(attrs, role),
           {:ok, invitation, encoded_token} <-
             insert_invitation(workspace, nil, attrs, role, validity_days) do
        if workspace_created? do
          Audit.record_event!(%{
            action: "workspace.created",
            target_type: "workspace",
            target_id: workspace.id,
            workspace_id: workspace.id,
            metadata: %{"source" => "operator"}
          })
        end

        Audit.record_event!(%{
          action: "invitation.created",
          target_type: "invitation",
          target_id: invitation.id,
          workspace_id: workspace.id,
          metadata: %{"role" => Atom.to_string(invitation.role), "source" => "operator"}
        })

        %{workspace: workspace, invitation: invitation, token: encoded_token}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def create_invitation(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{role: :owner},
          user: user
        },
        attrs
      )
      when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, role} <- normalize_role(value(attrs, :role, :member)),
           {:ok, validity_days} <- normalize_validity_days(value(attrs, :validity_days, nil)),
           {:ok, invitation, encoded_token} <-
             insert_invitation(workspace, user, attrs, role, validity_days) do
        Audit.record_event!(%{
          action: "invitation.created",
          target_type: "invitation",
          target_id: invitation.id,
          workspace_id: workspace.id,
          actor_user_id: user.id,
          metadata: %{"role" => Atom.to_string(invitation.role), "source" => "workspace"}
        })

        %{invitation: invitation, token: encoded_token}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def create_invitation(%Scope{}, _attrs), do: {:error, :owner_required}

  def get_invitation_by_token(encoded_token) when is_binary(encoded_token) do
    with {:ok, token_hash} <- decode_and_hash_token(encoded_token),
         %Invitation{} = invitation <-
           Invitation
           |> where([invitation], invitation.token_hash == ^token_hash)
           |> preload(:workspace)
           |> Repo.one(),
         :ok <- validate_pending_invitation(invitation) do
      {:ok, invitation}
    else
      nil -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def accept_invitation(encoded_token) when is_binary(encoded_token) do
    with {:ok, token_hash} <- decode_and_hash_token(encoded_token) do
      Repo.transaction(fn ->
        with %Invitation{} = invitation <- locked_invitation(token_hash),
             :ok <- validate_pending_invitation(invitation),
             {:ok, user} <- get_or_create_invited_user(invitation.email),
             :ok <- ensure_not_member(user, invitation.workspace_id),
             {:ok, membership} <- create_membership(invitation.workspace, user, invitation.role),
             {:ok, invitation} <- accept_locked_invitation(invitation, user) do
          record_acceptance_events(invitation, user, membership)

          %{
            user: user,
            workspace: invitation.workspace,
            membership: membership,
            invitation: invitation
          }
        else
          nil -> Repo.rollback(:invalid)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def revoke_invitation(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{role: :owner},
          user: user
        },
        invitation_id
      ) do
    Repo.transaction(fn ->
      invitation =
        Invitation
        |> where([invitation], invitation.id == ^invitation_id)
        |> where([invitation], invitation.workspace_id == ^workspace.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      with %Invitation{} = invitation <- invitation,
           :ok <- validate_pending_invitation(invitation),
           {:ok, invitation} <-
             invitation
             |> Invitation.revoke_changeset(DateTime.utc_now(:second))
             |> Repo.update() do
        Audit.record_event!(%{
          action: "invitation.revoked",
          target_type: "invitation",
          target_id: invitation.id,
          workspace_id: workspace.id,
          actor_user_id: user.id,
          metadata: %{}
        })

        invitation
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def revoke_invitation(%Scope{}, _invitation_id), do: {:error, :owner_required}

  def list_invitations(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{role: :owner}
      }) do
    Invitation
    |> where([invitation], invitation.workspace_id == ^workspace_id)
    |> order_by([invitation], desc: invitation.inserted_at)
    |> Repo.all()
  end

  def list_invitations(%Scope{}), do: {:error, :owner_required}

  def list_user_workspaces(%Scope{user: %User{id: user_id}}) do
    Membership
    |> join(:inner, [membership], workspace in assoc(membership, :workspace))
    |> where([membership], membership.user_id == ^user_id)
    |> where([_membership, workspace], workspace.status == :active and workspace.alpha_access)
    |> order_by([membership, workspace], asc: membership.inserted_at, asc: workspace.name)
    |> select([membership, workspace], {workspace, membership})
    |> Repo.all()
  end

  def scope_for_slug(%Scope{user: %User{id: user_id} = user}, slug) when is_binary(slug) do
    Membership
    |> join(:inner, [membership], workspace in assoc(membership, :workspace))
    |> where([membership], membership.user_id == ^user_id)
    |> where([_membership, workspace], workspace.slug == ^slug)
    |> where([_membership, workspace], workspace.status == :active and workspace.alpha_access)
    |> select([membership, workspace], {workspace, membership})
    |> Repo.one()
    |> case do
      {%Workspace{} = workspace, %Membership{} = membership} ->
        {:ok, Scope.for_workspace(user, workspace, membership)}

      nil ->
        {:error, :not_found}
    end
  end

  def default_workspace_scope(%Scope{} = scope) do
    case list_user_workspaces(scope) do
      [{workspace, membership} | _rest] ->
        {:ok, Scope.for_workspace(scope.user, workspace, membership)}

      [] ->
        {:error, :not_found}
    end
  end

  defp operator_workspace(attrs, role) do
    workspace_attrs = %{
      name: value(attrs, :workspace_name, nil),
      slug: value(attrs, :workspace_slug, nil),
      timezone: value(attrs, :timezone, "Etc/UTC")
    }

    changeset = Workspace.create_changeset(%Workspace{}, workspace_attrs)

    if changeset.valid? do
      slug = Ecto.Changeset.get_field(changeset, :slug)

      case Repo.get_by(Workspace, slug: slug) do
        %Workspace{} = workspace -> {:ok, {workspace, false}}
        nil when role == :owner -> insert_operator_workspace(changeset)
        nil -> {:error, :workspace_not_found}
      end
    else
      {:error, changeset}
    end
  end

  defp insert_operator_workspace(changeset) do
    case Repo.insert(changeset) do
      {:ok, workspace} -> {:ok, {workspace, true}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_invitation(workspace, inviter, attrs, role, validity_days) do
    email = value(attrs, :email, "") |> String.trim() |> String.downcase()
    now = DateTime.utc_now(:second)

    expire_stale_invitations(workspace.id, email, now)

    with :ok <- ensure_email_not_member(workspace.id, email) do
      raw_token = :crypto.strong_rand_bytes(@token_bytes)
      token_hash = :crypto.hash(@hash_algorithm, raw_token)
      encoded_token = Base.url_encode64(raw_token, padding: false)
      expires_at = DateTime.add(now, validity_days, :day)

      changeset =
        Invitation.create_changeset(
          %Invitation{},
          workspace,
          inviter,
          %{email: email, role: role},
          token_hash,
          expires_at
        )

      case Repo.insert(changeset) do
        {:ok, invitation} -> {:ok, invitation, encoded_token}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp expire_stale_invitations(workspace_id, email, now) do
    Invitation
    |> where([invitation], invitation.workspace_id == ^workspace_id)
    |> where([invitation], invitation.email == ^email)
    |> where([invitation], invitation.status == :pending)
    |> where([invitation], invitation.expires_at <= ^now)
    |> Repo.update_all(set: [status: :expired, updated_at: now])
  end

  defp ensure_email_not_member(workspace_id, email) do
    Membership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.workspace_id == ^workspace_id)
    |> where([_membership, user], user.email == ^email)
    |> Repo.exists?()
    |> if(do: {:error, :already_member}, else: :ok)
  end

  defp locked_invitation(token_hash) do
    Invitation
    |> where([invitation], invitation.token_hash == ^token_hash)
    |> lock("FOR UPDATE")
    |> preload(:workspace)
    |> Repo.one()
  end

  defp validate_pending_invitation(invitation) do
    case Invitation.state(invitation, DateTime.utc_now(:second)) do
      :pending -> :ok
      :expired -> {:error, :expired}
      :accepted -> {:error, :accepted}
      :revoked -> {:error, :revoked}
    end
  end

  defp get_or_create_invited_user(email) do
    case Accounts.get_user_by_email(email) do
      nil -> Accounts.create_user_from_invitation(email)
      %User{} = user -> Accounts.confirm_user_from_invitation(user)
    end
  end

  defp ensure_not_member(%User{id: user_id}, workspace_id) do
    if Repo.exists?(
         from membership in Membership,
           where: membership.user_id == ^user_id and membership.workspace_id == ^workspace_id
       ) do
      {:error, :already_member}
    else
      :ok
    end
  end

  defp create_membership(workspace, user, role) do
    %Membership{}
    |> Membership.create_changeset(workspace, user, role)
    |> Repo.insert()
  end

  defp accept_locked_invitation(invitation, user) do
    invitation
    |> Invitation.accept_changeset(user, DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp record_acceptance_events(invitation, user, membership) do
    common = %{workspace_id: invitation.workspace_id, actor_user_id: user.id}

    Audit.record_event!(
      Map.merge(common, %{
        action: "invitation.accepted",
        target_type: "invitation",
        target_id: invitation.id,
        metadata: %{"role" => Atom.to_string(invitation.role)}
      })
    )

    Audit.record_event!(
      Map.merge(common, %{
        action: "membership.created",
        target_type: "membership",
        target_id: membership.id,
        metadata: %{"role" => Atom.to_string(membership.role)}
      })
    )
  end

  defp decode_and_hash_token(encoded_token) do
    case Base.url_decode64(encoded_token, padding: false) do
      {:ok, raw_token} when byte_size(raw_token) == @token_bytes ->
        {:ok, :crypto.hash(@hash_algorithm, raw_token)}

      _other ->
        {:error, :invalid}
    end
  end

  defp normalize_role(role) when role in [:owner, :member], do: {:ok, role}
  defp normalize_role("owner"), do: {:ok, :owner}
  defp normalize_role("member"), do: {:ok, :member}
  defp normalize_role(_role), do: {:error, :invalid_role}

  defp normalize_validity_days(nil), do: {:ok, @default_validity_days}

  defp normalize_validity_days(days)
       when is_integer(days) and days >= 1 and days <= @maximum_validity_days,
       do: {:ok, days}

  defp normalize_validity_days(_days), do: {:error, :invalid_validity_days}

  defp value(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
