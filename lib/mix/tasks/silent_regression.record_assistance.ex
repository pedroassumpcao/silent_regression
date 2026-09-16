defmodule Mix.Tasks.SilentRegression.RecordAssistance do
  @shortdoc "Records content-free founder assistance for a private-alpha monitor"

  @moduledoc """
  Records one allowlisted founder-assistance event without accepting notes or customer content.

      mix silent_regression.record_assistance \
        --workspace-slug acme-ai \
        --monitor-id 00000000-0000-0000-0000-000000000000 \
        --actor-email founder@example.com \
        --stage contract \
        --reason onboarding

  Allowed stages are credential, workflow, cases, contract, baseline, schedule, and review.
  Allowed reasons are onboarding, correction, provider, security, and other.
  """

  use Mix.Task

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.ProductAnalytics
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @switches [
    workspace_slug: :string,
    monitor_id: :string,
    actor_email: :string,
    stage: :string,
    reason: :string
  ]

  @required Keyword.keys(@switches)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise(
        "Unknown assistance arguments. Run `mix help silent_regression.record_assistance`."
      )
    end

    attrs = opts |> Map.new() |> require_options!(@required)

    with {:ok, monitor_id} <- Ecto.UUID.cast(attrs.monitor_id),
         %Workspace{} = workspace <- Repo.get_by(Workspace, slug: attrs.workspace_slug),
         %User{} = user <- Repo.get_by(User, email: String.downcase(attrs.actor_email)),
         %Membership{role: :owner} = membership <- membership(workspace.id, user.id),
         %Monitor{} <-
           Repo.get_by(Monitor, id: monitor_id, workspace_id: workspace.id) do
      scope = Scope.for_workspace(user, workspace, membership)

      _event =
        ProductAnalytics.record_founder_assistance!(
          scope,
          monitor_id,
          attrs.stage,
          attrs.reason
        )

      Mix.shell().info("Founder assistance recorded")
      Mix.shell().info("Workspace: #{workspace.slug}")
      Mix.shell().info("Monitor: #{monitor_id}")
      Mix.shell().info("Stage: #{attrs.stage}")
      Mix.shell().info("Reason: #{attrs.reason}")
    else
      :error -> Mix.raise("monitor-id must be a UUID")
      nil -> Mix.raise("workspace, owner, or monitor not found")
      %Membership{} -> Mix.raise("actor-email must belong to a workspace owner")
    end
  rescue
    error in ArgumentError -> Mix.raise(error.message)
  end

  defp membership(workspace_id, user_id) do
    Repo.one(
      from membership in Membership,
        where: membership.workspace_id == ^workspace_id and membership.user_id == ^user_id
    )
  end

  defp require_options!(attrs, required) do
    missing = Enum.filter(required, &(Map.get(attrs, &1) in [nil, ""]))

    if missing == [] do
      attrs
    else
      names = Enum.map_join(missing, ", ", &"--#{String.replace(to_string(&1), "_", "-")}")
      Mix.raise("Missing required options: #{names}")
    end
  end
end
