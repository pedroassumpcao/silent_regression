defmodule SilentRegression.ProviderCredentials do
  @moduledoc """
  Workspace-scoped lifecycle management for encrypted provider credentials.

  Every public read returns a safe metadata map. The encrypted schema remains
  private to lifecycle and provider execution code.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.Monitors.{ModelCatalog, Monitor}
  alias SilentRegression.ProviderCredentials.{ModelValidation, ProviderCredential}
  alias SilentRegression.Providers
  alias SilentRegression.Providers.{CredentialValidation, Failure}
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @active_run_statuses [:planned, :queued, :running]

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

  def list_credential_overviews(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{}
        } = scope
      ) do
    credentials = list_credentials(scope)
    impacts = credential_impacts(workspace_id)
    verified_models = verified_models_by_credential(workspace_id)
    credentials_by_id = Map.new(credentials, &{&1.id, &1})

    successors =
      credentials
      |> Enum.reject(&(is_nil(&1.supersedes_id) or &1.status == :revoked))
      |> Map.new(&{&1.supersedes_id, &1.id})

    Enum.map(credentials, fn credential ->
      replacement_impact =
        if credential.supersedes_id && credential.status != :revoked do
          impacts
          |> Map.get(credential.supersedes_id, [])
          |> Enum.map(&impact_for_target(&1, credential.id))
        else
          []
        end

      predecessor = Map.get(credentials_by_id, credential.supersedes_id)

      replacement_pending =
        credential.status != :revoked and not is_nil(predecessor) and
          (credential.status != :valid or
             predecessor.status in [:pending_validation, :valid, :invalid] or
             Map.get(impacts, predecessor.id, []) != [])

      credential
      |> Map.put(
        :attached_monitors,
        impacts
        |> Map.get(credential.id, [])
        |> Enum.map(&impact_for_target(&1, credential.id))
      )
      |> Map.put(:replacement_impact, replacement_impact)
      |> Map.put(:replacement_pending, replacement_pending)
      |> Map.put(:successor_id, Map.get(successors, credential.id))
      |> Map.put(:verified_models, Map.get(verified_models, credential.id, []))
    end)
  end

  def list_credential_overviews(%Scope{}), do: {:error, :workspace_required}

  def list_selectable_credentials(%Scope{} = scope) do
    case list_credential_overviews(scope) do
      overviews when is_list(overviews) ->
        overviews
        |> Enum.filter(&(&1.status == :valid))
        |> Enum.reject(&(&1.replacement_pending or not is_nil(&1.successor_id)))
        |> Enum.map(&Map.take(&1, @safe_fields))

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  def model_access_verified?(%ProviderCredential{} = credential, model)
      when is_binary(model) do
    ModelValidation
    |> where(
      [validation],
      validation.workspace_id == ^credential.workspace_id and
        validation.provider_credential_id == ^credential.id and
        validation.requested_model == ^model and validation.returned_model == ^model and
        validation.status == :succeeded
    )
    |> Repo.exists?()
  end

  def model_access_verified?(_credential, _model), do: false

  def verified_models(%ProviderCredential{} = credential) do
    ModelValidation
    |> where(
      [validation],
      validation.workspace_id == ^credential.workspace_id and
        validation.provider_credential_id == ^credential.id and
        validation.status == :succeeded and
        validation.returned_model == validation.requested_model
    )
    |> order_by([validation], asc: validation.requested_model)
    |> select([validation], validation.requested_model)
    |> Repo.all()
  end

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
             :ok <- ensure_no_successor(credential),
             {:ok, successor} <-
               %ProviderCredential{}
               |> ProviderCredential.rotation_changeset(workspace, user, credential, attrs)
               |> Repo.insert(log: false) do
          record_event!(successor, user.id, "provider_credential.rotated", %{
            "supersedes_id" => credential.id
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

  def activate_replacement(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner}
        } = scope,
        successor_id
      ) do
    with {:ok, successor_id} <- cast_credential_id(successor_id),
         %ProviderCredential{} = successor <- load_credential(workspace_id, successor_id),
         :ok <- ensure_active(successor),
         %ProviderCredential{} = predecessor <- load_predecessor(successor),
         :ok <- ensure_replacement_pair(predecessor, successor),
         impact <- replacement_impact(workspace_id, predecessor.id),
         :ok <- ensure_no_replacement_work(impact.monitor_ids),
         :ok <- ensure_allowed_models(successor.provider, impact.requested_models),
         :ok <- validate_replacement_models(scope, successor, impact.requested_models) do
      finalize_replacement(scope, predecessor.id, successor.id, impact)
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def activate_replacement(%Scope{}, _successor_id), do: {:error, :owner_required}

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
      result =
        credential.provider
        |> Providers.validate_credential(credential.secret, options)
        |> require_exact_model()

      case persist_validation(workspace_id, credential_id, user, result) do
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

  defp finalize_replacement(scope, predecessor_id, successor_id, expected_impact) do
    Repo.transaction(fn ->
      with %ProviderCredential{} = predecessor <-
             lock_credential(scope.workspace.id, predecessor_id),
           %ProviderCredential{} = successor <- lock_credential(scope.workspace.id, successor_id),
           :ok <- ensure_active(successor),
           :ok <- ensure_replacement_pair(predecessor, successor),
           monitors <- locked_attached_monitors(scope.workspace.id, predecessor.id),
           current_impact <- impact_snapshot(monitors, approved_baselines(scope.workspace.id)),
           :ok <- ensure_impact_unchanged(expected_impact, current_impact),
           :ok <- ensure_no_replacement_work(current_impact.monitor_ids),
           :ok <- ensure_model_proof(successor, current_impact.requested_models),
           {:ok, predecessor, superseded?} <- supersede_predecessor(predecessor),
           {:ok, rebound} <- rebind_monitors(monitors, predecessor, successor, scope.user) do
        if superseded? do
          record_event!(predecessor, scope.user.id, "provider_credential.superseded", %{
            "successor_id" => successor.id
          })
        end

        record_event!(successor, scope.user.id, "provider_credential.replacement_activated", %{
          "predecessor_id" => predecessor.id,
          "affected_monitor_count" => length(rebound),
          "requested_model_count" => length(current_impact.requested_models),
          "reference_replacement_count" =>
            Enum.count(
              current_impact.requirements,
              &reference_replacement_required?(&1, successor.id)
            )
        })

        %{
          credential: to_safe_metadata(successor),
          affected_monitor_count: length(rebound),
          requested_models: current_impact.requested_models,
          reference_replacement_count:
            Enum.count(
              current_impact.requirements,
              &reference_replacement_required?(&1, successor.id)
            )
        }
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp validate_replacement_models(scope, successor, []) do
    case validate_credential(scope, successor.id) do
      {:ok, _credential} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_replacement_models(scope, successor, models) do
    Enum.reduce_while(models, :ok, fn model, :ok ->
      case validate_credential(scope, successor.id, %{model: model}) do
        {:ok, _credential} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_allowed_models(provider, models) do
    if Enum.all?(models, &match?({:ok, _pair}, ModelCatalog.validate(provider, &1))),
      do: :ok,
      else: {:error, :affected_model_not_allowed}
  end

  defp ensure_model_proof(%ProviderCredential{status: :valid} = successor, models) do
    if Enum.all?(models, &model_access_verified?(successor, &1)),
      do: :ok,
      else: {:error, :replacement_validation_stale}
  end

  defp ensure_model_proof(%ProviderCredential{}, _models),
    do: {:error, :replacement_validation_stale}

  defp ensure_impact_unchanged(expected, current) do
    if expected.requirements == current.requirements,
      do: :ok,
      else: {:error, :replacement_impact_changed}
  end

  defp ensure_no_replacement_work([]), do: :ok

  defp ensure_no_replacement_work(monitor_ids) do
    run_in_progress? =
      CaptureRun
      |> where(
        [run],
        run.monitor_id in ^monitor_ids and run.status in ^@active_run_statuses
      )
      |> Repo.exists?()

    reference_in_progress? =
      BaselineSnapshot
      |> where(
        [snapshot],
        snapshot.monitor_id in ^monitor_ids and snapshot.status == :pending
      )
      |> Repo.exists?()

    if run_in_progress? or reference_in_progress?,
      do: {:error, :replacement_work_in_progress},
      else: :ok
  end

  defp supersede_predecessor(%ProviderCredential{status: :superseded} = predecessor),
    do: {:ok, predecessor, false}

  defp supersede_predecessor(%ProviderCredential{status: :revoked} = predecessor),
    do: {:ok, predecessor, false}

  defp supersede_predecessor(%ProviderCredential{} = predecessor) do
    predecessor
    |> ProviderCredential.supersede_changeset(DateTime.utc_now(:second))
    |> Repo.update()
    |> case do
      {:ok, predecessor} -> {:ok, predecessor, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebind_monitors(monitors, predecessor, successor, user) do
    now = DateTime.utc_now(:second)

    Enum.reduce_while(monitors, {:ok, []}, fn monitor, {:ok, rebound} ->
      previous_state = monitor.state

      case monitor
           |> Monitor.credential_replacement_changeset(successor, now)
           |> Repo.update() do
        {:ok, updated} ->
          record_monitor_rebound!(updated, predecessor, successor, user, previous_state)
          {:cont, {:ok, [updated | rebound]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp record_monitor_rebound!(monitor, predecessor, successor, user, previous_state) do
    Audit.record_event!(%{
      action: "monitor.credential_rebound",
      target_type: "monitor",
      target_id: monitor.id,
      workspace_id: monitor.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "predecessor_credential_id" => predecessor.id,
        "successor_credential_id" => successor.id,
        "reference_policy" => "replacement_required",
        "from_state" => Atom.to_string(previous_state),
        "to_state" => Atom.to_string(monitor.state)
      }
    })
  end

  defp replacement_impact(workspace_id, predecessor_id) do
    workspace_id
    |> attached_monitors(predecessor_id)
    |> impact_snapshot(approved_baselines(workspace_id))
  end

  defp impact_snapshot(monitors, approved_baselines) do
    requirements =
      monitors
      |> Enum.map(&impact_requirement(&1, approved_baselines))
      |> Enum.sort_by(& &1.monitor_id)

    %{
      requirements: requirements,
      monitor_ids: Enum.map(requirements, & &1.monitor_id),
      requested_models:
        requirements
        |> Enum.flat_map(& &1.requested_models)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp impact_requirement(monitor, approved_baselines) do
    %{
      monitor_id: monitor.id,
      active_version_id: monitor.active_version_id,
      draft_version_id: monitor.draft_version_id,
      requested_models: requested_models(monitor),
      baseline_credential_id: Map.get(approved_baselines, monitor.id)
    }
  end

  defp credential_impacts(workspace_id) do
    approved_baselines = approved_baselines(workspace_id)

    Monitor
    |> where(
      [monitor],
      monitor.workspace_id == ^workspace_id and not is_nil(monitor.provider_credential_id)
    )
    |> order_by([monitor], asc: monitor.name, asc: monitor.id)
    |> preload([:active_version, :draft_version])
    |> Repo.all()
    |> Enum.group_by(& &1.provider_credential_id)
    |> Map.new(fn {credential_id, monitors} ->
      impacts = Enum.map(monitors, &monitor_impact(&1, approved_baselines))

      {credential_id, impacts}
    end)
  end

  defp monitor_impact(monitor, approved_baselines) do
    %{
      id: monitor.id,
      name: monitor.name,
      state: monitor.state,
      requested_models: requested_models(monitor),
      baseline_credential_id: Map.get(approved_baselines, monitor.id)
    }
  end

  defp impact_for_target(impact, credential_id) do
    impact
    |> Map.put(
      :reference_replacement_required,
      reference_replacement_required?(impact, credential_id)
    )
    |> Map.delete(:baseline_credential_id)
  end

  defp reference_replacement_required?(impact, credential_id) do
    not is_nil(impact.baseline_credential_id) and impact.baseline_credential_id != credential_id
  end

  defp requested_models(monitor) do
    [monitor.active_version, monitor.draft_version]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.requested_model)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp attached_monitors(workspace_id, credential_id) do
    Monitor
    |> where(
      [monitor],
      monitor.workspace_id == ^workspace_id and
        monitor.provider_credential_id == ^credential_id
    )
    |> order_by([monitor], asc: monitor.id)
    |> preload([:active_version, :draft_version])
    |> Repo.all()
  end

  defp locked_attached_monitors(workspace_id, credential_id) do
    monitors =
      Monitor
      |> where(
        [monitor],
        monitor.workspace_id == ^workspace_id and
          monitor.provider_credential_id == ^credential_id
      )
      |> order_by([monitor], asc: monitor.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    Repo.preload(monitors, [:active_version, :draft_version])
  end

  defp approved_baselines(workspace_id) do
    BaselineSnapshot
    |> where(
      [snapshot],
      snapshot.workspace_id == ^workspace_id and snapshot.status == :approved
    )
    |> select([snapshot], {snapshot.monitor_id, snapshot.provider_credential_id})
    |> Repo.all()
    |> Map.new()
  end

  defp verified_models_by_credential(workspace_id) do
    ModelValidation
    |> where(
      [validation],
      validation.workspace_id == ^workspace_id and validation.status == :succeeded and
        validation.returned_model == validation.requested_model
    )
    |> order_by([validation], asc: validation.requested_model)
    |> select([validation], {validation.provider_credential_id, validation.requested_model})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp ensure_no_successor(credential) do
    if Repo.exists?(
         from candidate in ProviderCredential,
           where: candidate.supersedes_id == ^credential.id and candidate.status != :revoked
       ),
       do: {:error, :replacement_pending},
       else: :ok
  end

  defp load_predecessor(%ProviderCredential{supersedes_id: nil}), do: nil

  defp load_predecessor(%ProviderCredential{} = successor) do
    load_credential(successor.workspace_id, successor.supersedes_id)
  end

  defp ensure_replacement_pair(predecessor, successor) do
    if successor.supersedes_id == predecessor.id and
         successor.workspace_id == predecessor.workspace_id and
         successor.provider == predecessor.provider and
         predecessor.status in [:pending_validation, :valid, :invalid, :revoked, :superseded] do
      :ok
    else
      {:error, :invalid_replacement}
    end
  end

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

  defp persist_validation(workspace_id, credential_id, user, result) do
    Repo.transaction(fn ->
      with %ProviderCredential{} = credential <- lock_credential(workspace_id, credential_id),
           :ok <- ensure_active(credential),
           at <- DateTime.utc_now(:second),
           {:ok, credential} <- update_validation(credential, result, at),
           :ok <- upsert_model_validation(credential, user, result, at) do
        record_validation_event!(credential, user.id, result)
        to_safe_metadata(credential)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_validation(credential, {:ok, %CredentialValidation{} = result}, at) do
    credential
    |> ProviderCredential.validation_changeset(result, at)
    |> Repo.update()
  end

  defp update_validation(credential, {:error, %Failure{} = failure}, at) do
    credential
    |> ProviderCredential.validation_changeset(failure, at)
    |> Repo.update()
  end

  defp upsert_model_validation(
         credential,
         user,
         {:ok, %CredentialValidation{requested_model: requested_model} = result},
         at
       )
       when is_binary(requested_model) do
    credential
    |> model_validation(requested_model)
    |> ModelValidation.success_changeset(credential, user, result, at)
    |> Repo.insert_or_update()
    |> case do
      {:ok, _validation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_model_validation(
         credential,
         user,
         {:error, %Failure{requested_model: requested_model} = failure},
         at
       )
       when is_binary(requested_model) do
    credential
    |> model_validation(requested_model)
    |> ModelValidation.failure_changeset(credential, user, failure, at)
    |> Repo.insert_or_update()
    |> case do
      {:ok, _validation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_model_validation(_credential, _user, _result, _at), do: :ok

  defp model_validation(credential, requested_model) do
    Repo.get_by(ModelValidation,
      provider_credential_id: credential.id,
      requested_model: requested_model
    ) || %ModelValidation{}
  end

  defp require_exact_model(
         {:ok,
          %CredentialValidation{
            requested_model: requested_model,
            returned_model: returned_model
          } = result}
       )
       when is_binary(requested_model) and requested_model != returned_model do
    {:error,
     %Failure{
       category: :model_mismatch,
       message: "The provider returned a different model identity than the one requested.",
       request_id: result.request_id,
       requested_model: requested_model,
       returned_model: returned_model,
       attempts: result.attempts
     }}
  end

  defp require_exact_model(result), do: result

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
