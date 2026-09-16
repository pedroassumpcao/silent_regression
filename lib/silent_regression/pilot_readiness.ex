defmodule SilentRegression.PilotReadiness do
  @moduledoc """
  Derives private-alpha activation state from authoritative workspace records.

  No mutable checklist state is stored. A completed step may become incomplete again when a
  credential is revoked, a baseline becomes incompatible, or a monitor is paused.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Baselines
  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.MonitorSetups.Setup
  alias SilentRegression.Monitors.{CaseVersion, Monitor}
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @steps [
    {:credential, "Connect a provider credential"},
    {:workflow, "Define the workflow"},
    {:cases, "Add representative cases"},
    {:contract, "Approve the deterministic contract"},
    {:baseline, "Approve the baseline"},
    {:schedule, "Activate monitoring"}
  ]

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

  defp candidates(workspace_id, scope) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id)
    |> order_by([monitor], asc: monitor.inserted_at, asc: monitor.id)
    |> Repo.all()
    |> Enum.map(&candidate(&1, scope))
  end

  defp candidate(monitor, scope) do
    setup = Repo.get_by(Setup, workspace_id: monitor.workspace_id, monitor_id: monitor.id)
    workflow? = setup && setup.status == :completed
    version_id = setup && setup.completed_monitor_version_id
    cases? = workflow? and active_case?(version_id)
    contract? = cases? and approved_contract?(monitor.id)
    baseline? = contract? and Baselines.compatible_approved?(scope, monitor.id)

    schedule? =
      baseline? and monitor.state == :active and monitor.cadence in [:daily, :weekly]

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
end
