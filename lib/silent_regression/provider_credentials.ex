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
  alias SilentRegression.Providers
  alias SilentRegression.Providers.{CredentialValidation, Failure}
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
    with {:ok, credential_id} <- cast_credential_id(credential_id) do
      ProviderCredential
      |> where([credential], credential.workspace_id == ^workspace_id)
      |> where([credential], credential.id == ^credential_id)
      |> select([credential], map(credential, ^@safe_fields))
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        credential -> {:ok, credential}
      end
    else
      :error -> {:error, :not_found}
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
      |> Repo.insert(log: false)
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
    with {:ok, credential_id} <- cast_credential_id(credential_id) do
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
               |> Repo.insert(log: false) do
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
    else
      :error -> {:error, :not_found}
    end
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
    with {:ok, credential_id} <- cast_credential_id(credential_id) do
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
    else
      :error -> {:error, :not_found}
    end
  end

  def revoke_credential(%Scope{}, _credential_id), do: {:error, :owner_required}

  def validate_credential(scope, credential_id, attrs \\ %{})

  def validate_credential(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: user
        },
        credential_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, credential_id} <- cast_credential_id(credential_id),
         {:ok, options} <- validation_options(attrs),
         %ProviderCredential{} = credential <- load_credential(workspace_id, credential_id),
         :ok <- ensure_active(credential) do
      result = Providers.validate_credential(credential.provider, credential.secret, options)

      case persist_validation(workspace_id, credential_id, user.id, result) do
        {:ok, metadata} -> return_validation(result, metadata)
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_credential(%Scope{}, _credential_id, _attrs), do: {:error, :owner_required}

  defp lock_credential(workspace_id, credential_id) do
    ProviderCredential
    |> where([credential], credential.workspace_id == ^workspace_id)
    |> where([credential], credential.id == ^credential_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_credential(workspace_id, credential_id) do
    ProviderCredential
    |> where([credential], credential.workspace_id == ^workspace_id)
    |> where([credential], credential.id == ^credential_id)
    |> Repo.one()
  end

  defp ensure_active(%ProviderCredential{status: status})
       when status in [:pending_validation, :valid, :invalid],
       do: :ok

  defp ensure_active(%ProviderCredential{}), do: {:error, :not_active}

  defp cast_credential_id(credential_id), do: Ecto.UUID.cast(credential_id)

  defp validation_options(attrs) do
    case Map.get(attrs, :model) || Map.get(attrs, "model") do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      model when is_binary(model) ->
        model = String.trim(model)

        if String.valid?(model) and model != "" and byte_size(model) <= 200 do
          {:ok, [model: model]}
        else
          {:error, :invalid_model}
        end

      _model ->
        {:error, :invalid_model}
    end
  end

  defp persist_validation(workspace_id, credential_id, actor_user_id, result) do
    Repo.transaction(fn ->
      with %ProviderCredential{} = credential <- lock_credential(workspace_id, credential_id),
           :ok <- ensure_active(credential),
           {:ok, credential} <- update_validation(credential, result) do
        record_validation_event!(credential, actor_user_id, result)
        to_safe_metadata(credential)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_validation(credential, {:ok, %CredentialValidation{} = result}) do
    credential
    |> ProviderCredential.validation_changeset(result, DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp update_validation(credential, {:error, %Failure{} = failure}) do
    credential
    |> ProviderCredential.validation_changeset(failure, DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp return_validation({:ok, %CredentialValidation{}}, metadata), do: {:ok, metadata}
  defp return_validation({:error, %Failure{} = failure}, _metadata), do: {:error, failure}

  defp record_validation_event!(credential, actor_user_id, result) do
    {action, result_metadata} = validation_event(result)

    record_event!(credential, actor_user_id, action, result_metadata)
  end

  defp validation_event({:ok, %CredentialValidation{} = result}) do
    {"provider_credential.validation_succeeded", validation_provenance(result)}
  end

  defp validation_event({:error, %Failure{} = failure}) do
    {"provider_credential.validation_failed",
     failure
     |> validation_provenance()
     |> Map.put("category", Atom.to_string(failure.category))}
  end

  defp validation_provenance(result) do
    %{"attempts" => result.attempts}
    |> put_optional_metadata("requested_model", result.requested_model)
    |> put_optional_metadata("returned_model", result.returned_model)
    |> put_optional_metadata("provider_request_id", result.request_id)
  end

  defp put_optional_metadata(metadata, _key, nil), do: metadata
  defp put_optional_metadata(metadata, key, value), do: Map.put(metadata, key, value)

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
