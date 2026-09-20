defmodule SilentRegression.Monitors do
  @moduledoc """
  Workspace-scoped monitor identity, immutable configuration, and lifecycle API.

  Owners and members may collaborate on monitors. Credential administration is
  kept behind the stricter owner-only boundary in `SilentRegression.ProviderCredentials`.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit

  alias SilentRegression.Monitors.{
    CaseVersion,
    Monitor,
    MonitorVersion,
    Provenance,
    VersionInput
  }

  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @states [:draft, :validating, :ready, :baseline_pending, :active, :paused, :archived]

  @type domain_error :: :not_found | :workspace_required | :archived | :unchanged_configuration

  def list_monitors(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{}
      }) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id)
    |> order_by([monitor], asc: monitor.name, asc: monitor.id)
    |> preload([:active_version, :draft_version])
    |> Repo.all()
  end

  def list_monitors(%Scope{}), do: {:error, :workspace_required}

  def get_monitor(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- cast_id(monitor_id),
         %Monitor{} = monitor <- load_monitor(workspace_id, monitor_id) do
      {:ok, Repo.preload(monitor, [:active_version, :draft_version])}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_monitor(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def create_monitor(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{},
          user: %User{} = user
        },
        attrs
      )
      when is_map(attrs) do
    Repo.transaction(fn ->
      case %Monitor{} |> Monitor.create_changeset(workspace, user, attrs) |> Repo.insert() do
        {:ok, monitor} ->
          record_event!(monitor, user, "monitor.created")
          monitor

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def create_monitor(%Scope{}, _attrs), do: {:error, :workspace_required}

  def update_monitor_metadata(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- cast_id(monitor_id) do
      Repo.transaction(fn ->
        case locked_monitor(workspace_id, monitor_id) do
          nil ->
            Repo.rollback(:not_found)

          monitor ->
            case monitor |> Monitor.metadata_changeset(attrs) |> Repo.update() do
              {:ok, updated} ->
                record_event!(updated, user, "monitor.metadata_updated")
                updated

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def update_monitor_metadata(%Scope{}, _monitor_id, _attrs),
    do: {:error, :workspace_required}

  def create_version(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- cast_id(monitor_id),
         {:ok, normalized} <- VersionInput.normalize(attrs) do
      Repo.transaction(fn ->
        with %Monitor{} = monitor <- locked_monitor(workspace_id, monitor_id),
             :ok <- ensure_editable(monitor),
             :ok <- ensure_changed(monitor, normalized),
             {:ok, version} <- insert_version(monitor, user, normalized) do
          record_version_event!(version, workspace_id, user, "monitor_version.created")
          Repo.preload(version, :cases)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_version(%Scope{}, _monitor_id, _attrs), do: {:error, :workspace_required}

  def list_versions(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- cast_id(monitor_id),
         %Monitor{} <- load_monitor(workspace_id, monitor_id) do
      MonitorVersion
      |> where([version], version.monitor_id == ^monitor_id)
      |> order_by([version], desc: version.version)
      |> preload(:cases)
      |> Repo.all()
    else
      _reason -> {:error, :not_found}
    end
  end

  def list_versions(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def get_version(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        version_id
      ) do
    with {:ok, version_id} <- cast_id(version_id),
         %MonitorVersion{} = version <- load_version(workspace_id, version_id) do
      {:ok, Repo.preload(version, :cases)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_version(%Scope{}, _version_id), do: {:error, :workspace_required}

  def activate_version(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        version_id
      ) do
    with {:ok, monitor_id} <- cast_id(monitor_id),
         {:ok, version_id} <- cast_id(version_id) do
      Repo.transaction(fn ->
        with %Monitor{} = monitor <- locked_monitor(workspace_id, monitor_id),
             :ok <- ensure_editable(monitor),
             %MonitorVersion{} = version <- load_monitor_version(monitor.id, version_id),
             :ok <- ensure_current_draft(monitor, version),
             previous_state <- monitor.state,
             {:ok, monitor, version} <- activate_locked_version(monitor, version) do
          record_version_event!(
            version,
            workspace_id,
            user,
            "monitor_version.activated"
          )

          record_event!(monitor, user, "monitor.state_changed", %{
            "from" => Atom.to_string(previous_state),
            "to" => "validating"
          })

          Repo.preload(monitor, [:active_version, :draft_version], force: true)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def activate_version(%Scope{}, _monitor_id, _version_id),
    do: {:error, :workspace_required}

  def transition_monitor(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        target
      ) do
    with {:ok, monitor_id} <- cast_id(monitor_id),
         {:ok, target} <- cast_state(target) do
      Repo.transaction(fn ->
        case locked_monitor(workspace_id, monitor_id) do
          nil ->
            Repo.rollback(:not_found)

          monitor ->
            previous_state = monitor.state

            with :ok <- ensure_configuration_for_state(monitor, target),
                 {:ok, monitor} <-
                   monitor
                   |> Monitor.transition_changeset(target, DateTime.utc_now(:second))
                   |> Repo.update() do
              record_state_event!(monitor, user, previous_state)
              monitor
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def transition_monitor(%Scope{}, _monitor_id, _target),
    do: {:error, :workspace_required}

  def prepare_baseline(scope, monitor_id, version_id, options \\ [])

  def prepare_baseline(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        monitor_id,
        version_id,
        options
      )
      when is_list(options) do
    with {:ok, monitor_id} <- cast_id(monitor_id),
         {:ok, version_id} <- cast_id(version_id) do
      Repo.transaction(fn ->
        with %Monitor{} = monitor <- locked_monitor(workspace_id, monitor_id),
             :ok <- ensure_editable(monitor),
             %MonitorVersion{} = version <- load_monitor_version(monitor.id, version_id),
             {:ok, monitor, activated?, prepared?} <-
               prepare_baseline_version(
                 monitor,
                 version,
                 Keyword.get(options, :replacement?, false)
               ) do
          if activated? do
            record_version_event!(
              version,
              workspace_id,
              user,
              "monitor_version.activated"
            )
          end

          if prepared? do
            record_event!(monitor, user, "monitor.baseline_prepared", %{
              "monitor_version_id" => version.id
            })
          end

          Repo.preload(monitor, [:active_version, :draft_version], force: true)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def prepare_baseline(%Scope{}, _monitor_id, _version_id, _options),
    do: {:error, :owner_required}

  def ensure_compatible_versions(%Scope{} = scope, reference_id, candidate_id) do
    with {:ok, reference} <- get_version(scope, reference_id),
         {:ok, candidate} <- get_version(scope, candidate_id) do
      reference
      |> Provenance.from_version()
      |> Provenance.ensure_compatible(Provenance.from_version(candidate))
    end
  end

  defp prepare_baseline_version(
         %Monitor{active_version_id: version_id, state: :baseline_pending} = monitor,
         %MonitorVersion{id: version_id, status: :active},
         _replacement?
       ),
       do: {:ok, monitor, false, false}

  defp prepare_baseline_version(
         %Monitor{active_version_id: version_id, state: state} = monitor,
         %MonitorVersion{id: version_id, status: :active},
         true
       )
       when state in [:active, :paused] do
    with {:ok, monitor} <-
           monitor
           |> Monitor.replacement_baseline_changeset(DateTime.utc_now(:second))
           |> Repo.update() do
      {:ok, monitor, false, true}
    end
  end

  defp prepare_baseline_version(
         %Monitor{active_version_id: version_id, state: state} = monitor,
         %MonitorVersion{id: version_id, status: :active},
         _replacement?
       )
       when state in [:validating, :ready] do
    with {:ok, monitor} <- advance_to_baseline_pending(monitor) do
      {:ok, monitor, false, true}
    end
  end

  defp prepare_baseline_version(
         %Monitor{draft_version_id: version_id} = monitor,
         %MonitorVersion{id: version_id, status: :draft} = version,
         _replacement?
       ) do
    with {:ok, monitor, _version} <- activate_locked_version(monitor, version),
         {:ok, monitor} <- advance_to_baseline_pending(monitor) do
      {:ok, monitor, true, true}
    end
  end

  defp prepare_baseline_version(%Monitor{}, %MonitorVersion{}, _replacement?),
    do: {:error, :not_current_configuration}

  defp advance_to_baseline_pending(%Monitor{state: :validating} = monitor) do
    with {:ok, monitor} <-
           monitor
           |> Monitor.transition_changeset(:ready, DateTime.utc_now(:second))
           |> Repo.update() do
      advance_to_baseline_pending(monitor)
    end
  end

  defp advance_to_baseline_pending(%Monitor{state: :ready} = monitor) do
    monitor
    |> Monitor.transition_changeset(:baseline_pending, DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp advance_to_baseline_pending(%Monitor{state: :baseline_pending} = monitor),
    do: {:ok, monitor}

  defp advance_to_baseline_pending(%Monitor{}), do: {:error, :invalid_monitor_state}

  defp insert_version(monitor, user, normalized) do
    now = DateTime.utc_now(:second)
    predecessor = load_predecessor(monitor)

    with {:ok, _old_draft} <- supersede_draft(predecessor.draft, now),
         version_number <- next_version_number(monitor.id),
         version_attrs <-
           normalized
           |> Map.delete(:cases)
           |> Map.merge(%{version: version_number, predecessor_id: predecessor.id}),
         {:ok, version} <-
           %MonitorVersion{}
           |> MonitorVersion.create_changeset(monitor, user, version_attrs)
           |> Repo.insert(),
         {:ok, _cases} <- insert_cases(version, user, normalized.cases),
         {:ok, _monitor} <-
           monitor |> Monitor.candidate_changeset(version) |> Repo.update() do
      {:ok, version}
    end
  end

  defp load_predecessor(monitor) do
    draft = load_owned_version(monitor.id, monitor.draft_version_id)
    active = load_owned_version(monitor.id, monitor.active_version_id)
    %{draft: draft, id: version_id(draft || active)}
  end

  defp supersede_draft(nil, _now), do: {:ok, nil}

  defp supersede_draft(%MonitorVersion{} = version, now) do
    version |> MonitorVersion.supersede_changeset(now) |> Repo.update()
  end

  defp insert_cases(version, user, cases) do
    Enum.reduce_while(cases, {:ok, []}, fn attrs, {:ok, inserted} ->
      case %CaseVersion{}
           |> CaseVersion.create_changeset(version, user, attrs)
           |> Repo.insert() do
        {:ok, case_version} -> {:cont, {:ok, [case_version | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp activate_locked_version(monitor, version) do
    now = DateTime.utc_now(:second)
    old_active = load_owned_version(monitor.id, monitor.active_version_id)

    with {:ok, _old_active} <- supersede_active(old_active, now),
         {:ok, version} <- version |> MonitorVersion.activate_changeset(now) |> Repo.update(),
         {:ok, monitor} <-
           monitor |> Monitor.activate_configuration_changeset(version, now) |> Repo.update() do
      {:ok, monitor, version}
    end
  end

  defp supersede_active(nil, _now), do: {:ok, nil}

  defp supersede_active(%MonitorVersion{} = version, now) do
    version |> MonitorVersion.supersede_changeset(now) |> Repo.update()
  end

  defp ensure_current_draft(
         %Monitor{draft_version_id: version_id},
         %MonitorVersion{id: version_id, status: :draft}
       ),
       do: :ok

  defp ensure_current_draft(_monitor, _version), do: {:error, :not_current_draft}

  defp ensure_editable(%Monitor{state: :archived}), do: {:error, :archived}
  defp ensure_editable(%Monitor{}), do: :ok

  defp ensure_changed(monitor, normalized) do
    current_id = monitor.draft_version_id || monitor.active_version_id

    monitor.id
    |> load_owned_version(current_id)
    |> case do
      nil ->
        :ok

      version ->
        version = Repo.preload(version, :cases)

        if same_configuration?(version, normalized),
          do: {:error, :unchanged_configuration},
          else: :ok
    end
  end

  defp same_configuration?(version, normalized) do
    version.schema_version == normalized.schema_version and
      version.provider == normalized.provider and
      version.requested_model == normalized.requested_model and
      version.system_prompt == normalized.system_prompt and
      version.user_prompt_template == normalized.user_prompt_template and
      version.response_format == normalized.response_format and
      version.generation_config == normalized.generation_config and
      normalized_cases(version.cases) == normalized.cases
  end

  defp normalized_cases(cases) do
    cases
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn case_version ->
      Map.take(case_version, [
        :case_key,
        :name,
        :position,
        :status,
        :input_variables,
        :frozen_context,
        :fingerprint
      ])
    end)
  end

  defp ensure_configuration_for_state(%Monitor{}, target) when target in [:draft, :archived],
    do: :ok

  defp ensure_configuration_for_state(%Monitor{active_version_id: nil}, _target),
    do: {:error, :active_configuration_required}

  defp ensure_configuration_for_state(%Monitor{}, _target), do: :ok

  defp next_version_number(monitor_id) do
    MonitorVersion
    |> where([version], version.monitor_id == ^monitor_id)
    |> select([version], max(version.version))
    |> Repo.one()
    |> case do
      nil -> 1
      version -> version + 1
    end
  end

  defp load_monitor(workspace_id, monitor_id) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id)
    |> where([monitor], monitor.id == ^monitor_id)
    |> Repo.one()
  end

  defp locked_monitor(workspace_id, monitor_id) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id)
    |> where([monitor], monitor.id == ^monitor_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp load_version(workspace_id, version_id) do
    MonitorVersion
    |> join(:inner, [version], monitor in assoc(version, :monitor))
    |> where([version, monitor], version.id == ^version_id)
    |> where([_version, monitor], monitor.workspace_id == ^workspace_id)
    |> Repo.one()
  end

  defp load_monitor_version(monitor_id, version_id) do
    MonitorVersion
    |> where([version], version.monitor_id == ^monitor_id)
    |> where([version], version.id == ^version_id)
    |> Repo.one()
  end

  defp load_owned_version(_monitor_id, nil), do: nil

  defp load_owned_version(monitor_id, version_id) do
    load_monitor_version(monitor_id, version_id)
  end

  defp version_id(nil), do: nil
  defp version_id(%MonitorVersion{id: id}), do: id

  defp cast_id(id), do: Ecto.UUID.cast(id)

  defp cast_state(target) when target in @states, do: {:ok, target}
  defp cast_state("draft"), do: {:ok, :draft}
  defp cast_state("validating"), do: {:ok, :validating}
  defp cast_state("ready"), do: {:ok, :ready}
  defp cast_state("baseline_pending"), do: {:ok, :baseline_pending}
  defp cast_state("active"), do: {:ok, :active}
  defp cast_state("paused"), do: {:ok, :paused}
  defp cast_state("archived"), do: {:ok, :archived}
  defp cast_state(_target), do: :error

  defp record_state_event!(monitor, user, previous_state) do
    action =
      case monitor.state do
        :paused -> "monitor.paused"
        :active -> "monitor.resumed"
        :archived -> "monitor.archived"
        _state -> "monitor.state_changed"
      end

    record_event!(monitor, user, action, %{
      "from" => Atom.to_string(previous_state),
      "to" => Atom.to_string(monitor.state)
    })
  end

  defp record_version_event!(version, workspace_id, user, action) do
    Audit.record_event!(%{
      action: action,
      target_type: "monitor_version",
      target_id: version.id,
      workspace_id: workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "monitor_id" => version.monitor_id,
        "version" => version.version,
        "provider" => Atom.to_string(version.provider),
        "requested_model" => version.requested_model
      }
    })
  end

  defp record_event!(monitor, user, action, metadata \\ %{}) do
    Audit.record_event!(%{
      action: action,
      target_type: "monitor",
      target_id: monitor.id,
      workspace_id: monitor.workspace_id,
      actor_user_id: user.id,
      metadata: metadata
    })
  end
end
