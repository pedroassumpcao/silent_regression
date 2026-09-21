defmodule SilentRegression.PilotReadiness do
  @moduledoc """
  Derives tenant onboarding state and enforces hosted-pilot operational readiness.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Baselines
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.MonitorSetups.Setup
  alias SilentRegression.Monitors.{CaseVersion, Monitor}
  alias SilentRegression.OperationalHealth
  alias SilentRegression.PilotReadiness.OperationalDrill
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @required_drills OperationalDrill.kinds()
  @release_bound_drills [:backup_restore, :rollback, :deletion_reconciliation]
  @steps [
    {:credential, "Connect a provider credential"},
    {:workflow, "Define the workflow"},
    {:cases, "Add representative cases"},
    {:contract, "Approve the deterministic contract"},
    {:baseline, "Approve the baseline"},
    {:schedule, "Enable manual or scheduled monitoring"}
  ]

  def record_drill(attrs, opts \\ []) when is_map(attrs) do
    config = config(opts)

    performed_at =
      value(attrs, :performed_at, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    validity_days = Keyword.fetch!(config, :drill_validity_days)

    attrs = %{
      kind: value(attrs, :kind),
      environment: value(attrs, :environment, Keyword.fetch!(config, :environment)),
      release_sha: value(attrs, :release_sha, Keyword.fetch!(config, :release_sha)),
      outcome: value(attrs, :outcome),
      operator_identifier: value(attrs, :operator_identifier),
      evidence_ref: value(attrs, :evidence_ref),
      performed_at: performed_at,
      expires_at: DateTime.add(performed_at, validity_days, :day)
    }

    %OperationalDrill{}
    |> OperationalDrill.changeset(attrs)
    |> Repo.insert()
  end

  def status(opts \\ []) do
    config = config(opts)
    now = Keyword.get(opts, :at, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
    environment = Keyword.fetch!(config, :environment)
    release_sha = Keyword.fetch!(config, :release_sha)

    latest =
      OperationalDrill
      |> where([drill], drill.environment == ^environment)
      |> order_by([drill], desc: drill.performed_at, desc: drill.id)
      |> Repo.all()
      |> Enum.reduce(%{}, fn drill, acc -> Map.put_new(acc, drill.kind, drill) end)

    drills =
      Enum.map(@required_drills, fn kind ->
        drill = latest[kind]
        current? = current_drill?(drill, kind, release_sha, now)

        %{
          kind: kind,
          current: current?,
          outcome: drill && drill.outcome,
          performed_at: drill && drill.performed_at,
          expires_at: drill && drill.expires_at,
          release_matches: drill && release_matches?(drill, kind, release_sha)
        }
      end)

    operational_health = OperationalHealth.snapshot(at: DateTime.truncate(now, :second))
    drills_current? = Enum.all?(drills, & &1.current)
    health_ready? = operational_health.status == :ok
    enabled? = Keyword.fetch!(config, :invitations_enabled)

    %{
      ready: drills_current? and health_ready? and enabled?,
      environment: environment,
      release_sha: release_sha,
      enforcement: Keyword.fetch!(config, :enforce_invitation_gate),
      invitations_enabled: enabled?,
      drills_current: drills_current?,
      operational_health: operational_health.status,
      drills: drills
    }
  end

  def authorize_invitation(opts \\ []) do
    config = config(opts)

    if Keyword.fetch!(config, :enforce_invitation_gate) do
      readiness = status(Keyword.put(opts, :config, config))

      cond do
        not readiness.invitations_enabled -> {:error, :pilot_invitations_disabled}
        not readiness.drills_current -> {:error, :operational_drills_incomplete}
        readiness.operational_health != :ok -> {:error, :operational_health_not_ready}
        true -> :ok
      end
    else
      :ok
    end
  end

  def required_drills, do: @required_drills

  def onboarding(
        %Scope{
          workspace: %Workspace{id: workspace_id, slug: slug},
          membership: %Membership{}
        } = scope
      ) do
    credential_ready? = valid_credential?(workspace_id)

    candidate =
      workspace_id
      |> candidates(scope)
      |> Enum.max_by(& &1.completed_count, fn -> empty_candidate() end)

    completed = %{
      credential: credential_ready?,
      workflow: candidate.workflow?,
      cases: candidate.cases?,
      contract: candidate.contract?,
      baseline: candidate.baseline?,
      schedule: candidate.schedule?
    }

    completed_count = Enum.count(@steps, fn {key, _label} -> Map.fetch!(completed, key) end)

    %{
      completed_count: completed_count,
      total_count: length(@steps),
      percent: div(completed_count * 100, length(@steps)),
      complete: completed_count == length(@steps),
      recurring_enabled: candidate.schedule? and candidate.monitor.cadence in [:daily, :weekly],
      monitor_id: candidate.monitor && candidate.monitor.id,
      monitor_name: candidate.monitor && candidate.monitor.name,
      steps:
        Enum.map(@steps, fn {key, label} ->
          %{
            key: key,
            label: label,
            complete: Map.fetch!(completed, key),
            href: step_href(key, slug, candidate.monitor)
          }
        end)
    }
  end

  def onboarding(%Scope{}), do: {:error, :workspace_required}

  defp current_drill?(nil, _kind, _release_sha, _now), do: false

  defp current_drill?(drill, kind, release_sha, now) do
    drill.outcome == :passed and DateTime.after?(drill.expires_at, now) and
      release_matches?(drill, kind, release_sha)
  end

  defp release_matches?(drill, kind, release_sha) when kind in @release_bound_drills,
    do: drill.release_sha == release_sha

  defp release_matches?(_drill, _kind, _release_sha), do: true

  defp config(opts) do
    Keyword.get(opts, :config, Application.fetch_env!(:silent_regression, :pilot_readiness))
  end

  defp candidates(workspace_id, scope) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id)
    |> order_by([monitor], asc: monitor.inserted_at, asc: monitor.id)
    |> Repo.all()
    |> Enum.map(&candidate(&1, scope))
  end

  defp candidate(monitor, scope) do
    setups =
      from setup in Setup,
        where: setup.workspace_id == ^monitor.workspace_id and setup.monitor_id == ^monitor.id,
        order_by: [desc: setup.inserted_at, desc: setup.id],
        limit: 1

    setups =
      if monitor.active_version_id do
        where(setups, [setup], setup.completed_monitor_version_id == ^monitor.active_version_id)
      else
        setups
      end

    setup = Repo.one(setups)
    workflow? = not is_nil(setup) and setup.status == :completed
    version_id = setup && setup.completed_monitor_version_id
    cases? = workflow? and active_case?(version_id)
    contract? = cases? and approved_contract?(monitor.id)
    baseline? = contract? and Baselines.compatible_approved?(scope, monitor.id)

    schedule? =
      baseline? and monitor.state == :active and monitor.cadence in [:manual, :daily, :weekly]

    flags = [workflow?, cases?, contract?, baseline?, schedule?]

    %{
      monitor: monitor,
      workflow?: truthy?(workflow?),
      cases?: truthy?(cases?),
      contract?: truthy?(contract?),
      baseline?: truthy?(baseline?),
      schedule?: truthy?(schedule?),
      completed_count: Enum.count(flags, &truthy?/1)
    }
  end

  defp empty_candidate do
    %{
      monitor: nil,
      workflow?: false,
      cases?: false,
      contract?: false,
      baseline?: false,
      schedule?: false,
      completed_count: 0
    }
  end

  defp valid_credential?(workspace_id) do
    Repo.exists?(
      from credential in ProviderCredential,
        where: credential.workspace_id == ^workspace_id and credential.status == :valid
    )
  end

  defp active_case?(nil), do: false

  defp active_case?(version_id) do
    Repo.exists?(
      from case_version in CaseVersion,
        where: case_version.monitor_version_id == ^version_id and case_version.status == :active
    )
  end

  defp approved_contract?(monitor_id) do
    Repo.exists?(
      from contract in ContractVersion,
        where: contract.monitor_id == ^monitor_id and contract.status == :approved
    )
  end

  defp step_href(:credential, slug, _monitor), do: "/app/#{slug}/credentials"
  defp step_href(:workflow, slug, nil), do: "/app/#{slug}/monitors/new"
  defp step_href(:cases, slug, nil), do: "/app/#{slug}/monitors/new"
  defp step_href(:contract, slug, nil), do: "/app/#{slug}/monitors/new"
  defp step_href(:baseline, slug, nil), do: "/app/#{slug}/monitors/new"
  defp step_href(:schedule, slug, nil), do: "/app/#{slug}/monitors/new"

  defp step_href(:workflow, slug, monitor),
    do: "/app/#{slug}/monitors/#{monitor.id}/setup"

  defp step_href(:cases, slug, monitor),
    do: "/app/#{slug}/monitors/#{monitor.id}/setup/cases"

  defp step_href(:contract, slug, monitor),
    do: "/app/#{slug}/monitors/#{monitor.id}/contract"

  defp step_href(:baseline, slug, monitor),
    do: "/app/#{slug}/monitors/#{monitor.id}/baseline"

  defp step_href(:schedule, slug, monitor),
    do: "/app/#{slug}/monitors/#{monitor.id}/operations"

  defp truthy?(value), do: value == true

  defp value(attrs, key, default \\ nil) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> default
      value -> value
    end
  end
end
