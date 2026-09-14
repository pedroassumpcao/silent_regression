defmodule SilentRegression.ProviderCredentials do
  @moduledoc """
  Workspace-scoped lifecycle management for encrypted provider credentials.

  Every public read returns a safe metadata map. The encrypted schema remains
  private to lifecycle and provider execution code.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @safe_fields [
    :id,
    :provider,
    :label,
    :secret_suffix,
    :status,
    :last_validation_status,
    :last_failure_category,
    :last_validated_at,
    :last_requested_model,
    :last_returned_model,
    :last_provider_request_id,
    :last_validation_attempts,
    :revoked_at,
    :superseded_at,
    :supersedes_id,
    :inserted_at,
    :updated_at
  ]

  def list_credentials(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{}
      }) do
    ProviderCredential
    |> where([credential], credential.workspace_id == ^workspace_id)
    |> order_by([credential], desc: credential.inserted_at, desc: credential.id)
    |> select([credential], map(credential, ^@safe_fields))
    |> Repo.all()
  end

  def list_credentials(%Scope{}), do: {:error, :workspace_required}

  def get_credential(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{}
        },
        credential_id
      ) do
    ProviderCredential
    |> where([credential], credential.workspace_id == ^workspace_id)
    |> where([credential], credential.id == ^credential_id)
    |> select([credential], map(credential, ^@safe_fields))
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      credential -> {:ok, credential}
    end
  end

  def get_credential(%Scope{}, _credential_id), do: {:error, :workspace_required}

  def create_credential(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{role: :owner},
          user: user
        },
        attrs
      )
      when is_map(attrs) do
    Repo.transaction(fn ->
      %ProviderCredential{}
      |> ProviderCredential.create_changeset(workspace, user, attrs)
      |> Repo.insert()
      |> case do
        {:ok, credential} ->
          record_event!(credential, user.id, "provider_credential.created")
          to_safe_metadata(credential)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def create_credential(%Scope{}, _attrs), do: {:error, :owner_required}

  def rotate_credential(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{role: :owner},
          user: user
        },
        credential_id,
        attrs
      )
      when is_map(attrs) do
    Repo.transaction(fn ->
      with %ProviderCredential{} = credential <- lock_credential(workspace.id, credential_id),
           :ok <- ensure_active(credential),
           {:ok, superseded} <-
             credential
             |> ProviderCredential.supersede_changeset(DateTime.utc_now(:second))
             |> Repo.update(),
           {:ok, successor} <-
             %ProviderCredential{}
             |> ProviderCredential.rotation_changeset(workspace, user, superseded, attrs)
             |> Repo.insert() do
        record_event!(superseded, user.id, "provider_credential.superseded", %{
          "successor_id" => successor.id
        })

        record_event!(successor, user.id, "provider_credential.rotated", %{
          "supersedes_id" => superseded.id
        })

        to_safe_metadata(successor)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def rotate_credential(%Scope{}, _credential_id, _attrs), do: {:error, :owner_required}

  def revoke_credential(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: user
        },
        credential_id
      ) do
    Repo.transaction(fn ->
      with %ProviderCredential{} = credential <- lock_credential(workspace_id, credential_id),
           :ok <- ensure_active(credential),
           {:ok, revoked} <-
             credential
             |> ProviderCredential.revoke_changeset(user, DateTime.utc_now(:second))
             |> Repo.update() do
        record_event!(revoked, user.id, "provider_credential.revoked")
        to_safe_metadata(revoked)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def revoke_credential(%Scope{}, _credential_id), do: {:error, :owner_required}

  defp lock_credential(workspace_id, credential_id) do
    ProviderCredential
    |> where([credential], credential.workspace_id == ^workspace_id)
    |> where([credential], credential.id == ^credential_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp ensure_active(%ProviderCredential{status: status})
       when status in [:pending_validation, :valid, :invalid],
       do: :ok

  defp ensure_active(%ProviderCredential{}), do: {:error, :not_active}

  defp record_event!(credential, actor_user_id, action, extra_metadata \\ %{}) do
    Audit.record_event!(%{
      action: action,
      target_type: "provider_credential",
      target_id: credential.id,
      workspace_id: credential.workspace_id,
      actor_user_id: actor_user_id,
      metadata:
        Map.merge(
          %{"provider" => Atom.to_string(credential.provider)},
          extra_metadata
        )
    })
  end

  defp to_safe_metadata(%ProviderCredential{} = credential) do
    Map.take(credential, @safe_fields)
  end
end
