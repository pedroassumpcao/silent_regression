defmodule SilentRegression.RunResults.Incidents do
  @moduledoc """
  Stable incident grouping, forward-only lifecycle, and immutable occurrence history.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit
  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.Repo
  alias SilentRegression.Reviews
  alias SilentRegression.RunResults.{Alert, Incident, IncidentOccurrence}
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @page_size 20
  @occurrence_page_size 25
  @recurrence_notification_counts [5, 20, 50]

  @doc false
  def attach_finding!(%CaptureRun{} = run, %Alert{} = alert, finding) when is_map(finding) do
    case occurrence_for_alert(alert.id) do
      %IncidentOccurrence{} = occurrence ->
        %{
          incident: Repo.get!(Incident, occurrence.result_incident_id),
          occurrence: occurrence,
          event: :existing
        }

      nil ->
        signature = Map.fetch!(finding, :incident_signature)
        advisory_lock!(run.workspace_id, signature)

        case active_incident(run.workspace_id, signature) do
          %Incident{} = incident ->
            attach_occurrence!(incident, run, alert, finding, incident.occurrence_count + 1)

          nil ->
            incident = create_incident!(run, finding)
            attach_occurrence!(incident, run, alert, finding, 1)
        end
    end
  end

  @doc false
  def recover_for_clean_run!(%CaptureRun{} = run) do
    at = run.completed_at || DateTime.utc_now()

    incidents =
      Incident
      |> where(
        [incident],
        incident.workspace_id == ^run.workspace_id and
          incident.monitor_id == ^run.monitor_id and
          incident.monitor_version_id == ^run.monitor_version_id and
          incident.status in [:open, :acknowledged]
      )
      |> lock("FOR UPDATE")
      |> Repo.all()

    Enum.each(incidents, fn incident ->
      recovered = incident |> Incident.recover_changeset(run, at) |> Repo.update!()

      Audit.record_event!(%{
        action: "incident.recovered",
        target_type: "result_incident",
        target_id: recovered.id,
        workspace_id: recovered.workspace_id,
        actor_user_id: nil,
        metadata: %{
          "capture_run_id" => run.id,
          "occurrence_count" => recovered.occurrence_count
        }
      })
    end)

    length(incidents)
  end

  def list_workspace(scope, params \\ %{})

  def list_workspace(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{} = membership
        },
        params
      ) do
    base = from incident in Incident, where: incident.workspace_id == ^workspace_id
    total = Repo.aggregate(base, :count)
    page = normalized_page(params, @page_size, total)
    offset = (page - 1) * @page_size

    incidents =
      base
      |> order_by(
        [incident],
        asc:
          fragment(
            "CASE ? WHEN 'open' THEN 0 WHEN 'acknowledged' THEN 1 WHEN 'recovered' THEN 2 ELSE 3 END",
            incident.status
          ),
        asc: fragment("CASE ? WHEN 'critical' THEN 0 ELSE 1 END", incident.severity),
        desc: incident.last_seen_at,
        desc: incident.id
      )
      |> limit(@page_size)
      |> offset(^offset)
      |> preload([:monitor, :acknowledged_by_user, :resolved_by_user])
      |> Repo.all()

    items = Enum.map(incidents, &%{incident: &1, latest_occurrence: latest_occurrence(&1.id)})

    counts =
      base
      |> group_by([incident], incident.status)
      |> select([incident], {incident.status, count(incident.id)})
      |> Repo.all()
      |> Map.new()

    {:ok,
     %{
       incidents: items,
       counts: counts,
       pagination: pagination(page, @page_size, total),
       can_resolve?: membership.role == :owner
     }}
  end

  def list_workspace(%Scope{}, _params), do: {:error, :workspace_required}

  def get_detail(scope, incident_id, params \\ %{})

  def get_detail(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{} = membership},
        incident_id,
        params
      ) do
    with {:ok, incident_id} <- Ecto.UUID.cast(incident_id),
         %Incident{} = incident <- load_incident(workspace_id, incident_id) do
      total = Repo.aggregate(occurrence_query(incident.id), :count)
      page = normalized_page(params, @occurrence_page_size, total)
      offset = (page - 1) * @occurrence_page_size
      occurrence_base = occurrence_query(incident.id)

      occurrences =
        occurrence_base
        |> limit(@occurrence_page_size)
        |> offset(^offset)
        |> Repo.all()

      latest_occurrence = latest_occurrence(incident.id)

      {:ok,
       %{
         incident: incident,
         latest_occurrence: latest_occurrence,
         occurrences: occurrences,
         pagination: pagination(page, @occurrence_page_size, total),
         can_resolve?: membership.role == :owner
       }}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_detail(%Scope{}, _incident_id, _params), do: {:error, :workspace_required}

  def acknowledge(scope, incident_id, options \\ [])

  def acknowledge(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        incident_id,
        options
      ) do
    with {:ok, incident_id} <- Ecto.UUID.cast(incident_id) do
      Repo.transaction(fn ->
        case locked_incident(workspace_id, incident_id) do
          %Incident{status: :open} = incident ->
            at = operation_time(options)
            incident = incident |> Incident.acknowledge_changeset(user, at) |> Repo.update!()
            record_lifecycle!(incident, user, "incident.acknowledged", at)
            incident

          %Incident{} = incident ->
            incident

          nil ->
            Repo.rollback(:not_found)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def acknowledge(%Scope{}, _incident_id, _options), do: {:error, :workspace_required}

  def resolve(scope, incident_id, options \\ [])

  def resolve(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        incident_id,
        options
      ) do
    with {:ok, incident_id} <- Ecto.UUID.cast(incident_id) do
      Repo.transaction(fn ->
        case locked_incident(workspace_id, incident_id) do
          %Incident{status: :acknowledged} = incident ->
            with %IncidentOccurrence{} = occurrence <- latest_occurrence(incident.id),
                 review when not is_nil(review) <-
                   Reviews.locked_current_for_alert(workspace_id, occurrence.result_alert_id) do
              at = operation_time(options)

              incident =
                incident |> Incident.resolve_changeset(user, review, at) |> Repo.update!()

              record_lifecycle!(incident, user, "incident.resolved", at)
              incident
            else
              nil -> Repo.rollback(:review_required)
            end

          %Incident{status: status} = incident when status in [:resolved, :recovered] ->
            incident

          %Incident{status: :open} ->
            Repo.rollback(:acknowledgement_required)

          nil ->
            Repo.rollback(:not_found)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :not_found}
    end
  end

  def resolve(%Scope{}, _incident_id, _options), do: {:error, :owner_required}

  def notification_event?(:opened), do: true
  def notification_event?({:recurrence, count}), do: count in @recurrence_notification_counts
  def notification_event?(_event), do: false

  defp create_incident!(run, finding) do
    previous = latest_incident(run.workspace_id, Map.fetch!(finding, :incident_signature))
    episode = if previous, do: previous.episode + 1, else: 1
    at = run.completed_at || DateTime.utc_now()
    case_fingerprints = Map.get(finding, :incident_case_fingerprints, []) |> Enum.uniq()

    associations = %{
      workspace_id: run.workspace_id,
      monitor_id: run.monitor_id,
      monitor_version_id: run.monitor_version_id,
      reopened_from_id: previous && previous.id
    }

    attrs = %{
      signature: Map.fetch!(finding, :incident_signature),
      signature_schema_version: Map.fetch!(finding, :incident_signature_schema_version),
      signature_components: Map.fetch!(finding, :incident_signature_components),
      episode: episode,
      category: finding.category,
      severity: finding.severity,
      code: finding.code,
      title: finding.title,
      explanation: finding.explanation,
      first_seen_at: at,
      last_seen_at: at,
      affected_case_count: length(case_fingerprints)
    }

    %Incident{} |> Incident.create_changeset(associations, attrs) |> Repo.insert!()
  end

  defp attach_occurrence!(incident, run, alert, finding, ordinal) do
    case_fingerprints =
      Map.get(finding, :incident_case_fingerprints, []) |> Enum.uniq() |> Enum.sort()

    occurrence =
      %IncidentOccurrence{}
      |> IncidentOccurrence.create_changeset(incident, alert, run, %{
        ordinal: ordinal,
        occurred_at: alert.opened_at,
        case_fingerprints: case_fingerprints,
        exceptional_reference: exceptional_reference?(run)
      })
      |> Repo.insert!()

    if ordinal == 1 do
      %{incident: incident, occurrence: occurrence, event: :opened}
    else
      affected_case_count = affected_case_count(incident.id)

      incident =
        incident
        |> Incident.recurrence_changeset(%{
          last_seen_at: alert.opened_at,
          occurrence_count: ordinal,
          run_count: incident.run_count + 1,
          affected_case_count: affected_case_count
        })
        |> Repo.update!()

      %{incident: incident, occurrence: occurrence, event: {:recurrence, ordinal}}
    end
  end

  defp active_incident(workspace_id, signature) do
    Incident
    |> where(
      [incident],
      incident.workspace_id == ^workspace_id and incident.signature == ^signature and
        incident.status in [:open, :acknowledged]
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp latest_incident(workspace_id, signature) do
    Incident
    |> where(
      [incident],
      incident.workspace_id == ^workspace_id and incident.signature == ^signature
    )
    |> order_by([incident], desc: incident.episode)
    |> limit(1)
    |> Repo.one()
  end

  defp occurrence_for_alert(alert_id) do
    Repo.get_by(IncidentOccurrence, result_alert_id: alert_id)
  end

  defp latest_occurrence(incident_id) do
    incident_id
    |> occurrence_query()
    |> limit(1)
    |> Repo.one()
  end

  defp occurrence_query(incident_id) do
    IncidentOccurrence
    |> where([occurrence], occurrence.result_incident_id == ^incident_id)
    |> order_by([occurrence], desc: occurrence.ordinal, desc: occurrence.id)
    |> preload([:capture_run, alert: [:capture_run, :capture_evaluation]])
  end

  defp affected_case_count(incident_id) do
    IncidentOccurrence
    |> where([occurrence], occurrence.result_incident_id == ^incident_id)
    |> select([occurrence], occurrence.case_fingerprints)
    |> Repo.all()
    |> List.flatten()
    |> MapSet.new()
    |> MapSet.size()
  end

  defp exceptional_reference?(%CaptureRun{baseline_snapshot: %{approval_mode: mode}}),
    do: mode != :normal

  defp exceptional_reference?(_run), do: false

  defp load_incident(workspace_id, incident_id) do
    Incident
    |> where([incident], incident.workspace_id == ^workspace_id and incident.id == ^incident_id)
    |> preload([
      :monitor,
      :monitor_version,
      :acknowledged_by_user,
      :resolved_by_user,
      :resolution_review_decision,
      :recovery_capture_run
    ])
    |> Repo.one()
  end

  defp locked_incident(workspace_id, incident_id) do
    Incident
    |> where([incident], incident.workspace_id == ^workspace_id and incident.id == ^incident_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp advisory_lock!(workspace_id, signature) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "#{workspace_id}:#{signature}"
    ])
  end

  defp record_lifecycle!(incident, user, action, at) do
    Audit.record_event!(%{
      action: action,
      target_type: "result_incident",
      target_id: incident.id,
      workspace_id: incident.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "episode" => incident.episode,
        "occurrence_count" => incident.occurrence_count,
        "at" => DateTime.to_iso8601(at)
      }
    })
  end

  defp page_number(params) do
    value = Map.get(params, "page", Map.get(params, :page, 1))

    case value do
      integer when is_integer(integer) and integer > 0 ->
        integer

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {integer, ""} when integer > 0 -> integer
          _result -> 1
        end

      _value ->
        1
    end
  end

  defp normalized_page(params, page_size, total) do
    requested = page_number(params)
    total_pages = max(1, ceil(total / page_size))
    min(requested, total_pages)
  end

  defp pagination(page, page_size, total) do
    total_pages = max(1, ceil(total / page_size))

    %{
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages,
      has_previous: page > 1,
      has_next: page < total_pages
    }
  end

  defp operation_time(options) do
    case Keyword.get(options, :at) do
      %DateTime{} = at -> DateTime.truncate(at, :microsecond)
      nil -> DateTime.utc_now()
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
