defmodule Mix.Tasks.SilentRegression.PilotMetrics do
  @shortdoc "Reports content-free pilot onboarding and demo measures"

  @moduledoc """
  Reports allowlisted, content-free activation and credential-free demo measures for one workspace.

      mix silent_regression.pilot_metrics \
        --workspace-slug acme-ai \
        --actor-email owner@acme.example

  The actor must be a workspace owner. The report never prints prompts, case inputs, outputs,
  credentials, review rationale, or event-level user identifiers.
  """

  use Mix.Task

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.ProductAnalytics
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @switches [workspace_slug: :string, actor_email: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Unknown metrics arguments. Run `mix help silent_regression.pilot_metrics`.")
    end

    attrs = opts |> Map.new() |> require_options!()

    with %Workspace{} = workspace <- Repo.get_by(Workspace, slug: attrs.workspace_slug),
         %User{} = user <- Repo.get_by(User, email: String.downcase(attrs.actor_email)),
         %Membership{role: :owner} = membership <- membership(workspace.id, user.id) do
      scope = Scope.for_workspace(user, workspace, membership)
      activation = ProductAnalytics.activation_funnel(scope)
      demo = ProductAnalytics.demo_funnel(scope)

      Mix.shell().info("Private-alpha product measures")
      Mix.shell().info("Workspace: #{workspace.slug}")
      Mix.shell().info("Activation seconds: #{value(activation.seconds_to_first_monitor)}")
      Mix.shell().info("Demo started/completed: #{demo.started_count}/#{demo.completed_count}")

      Mix.shell().info(
        "Demo median seconds to expectation/completion: #{value(demo.median_seconds_to_expectation)}/#{value(demo.median_seconds_to_completion)}"
      )

      Mix.shell().info("Demo founder-assistance events: #{demo.assistance_count}")

      for step <- ~w(request expectation reference incident) do
        Mix.shell().info("Demo step #{step}: #{Map.get(demo.step_counts, step, 0)}")
      end
    else
      nil -> Mix.raise("workspace or owner not found")
      %Membership{} -> Mix.raise("actor-email must belong to a workspace owner")
    end
  end

  defp membership(workspace_id, user_id) do
    Repo.one(
      from membership in Membership,
        where: membership.workspace_id == ^workspace_id and membership.user_id == ^user_id
    )
  end

  defp require_options!(attrs) do
    missing = Enum.filter([:workspace_slug, :actor_email], &(Map.get(attrs, &1) in [nil, ""]))

    if missing == [] do
      attrs
    else
      names = Enum.map_join(missing, ", ", &"--#{String.replace(to_string(&1), "_", "-")}")
      Mix.raise("Missing required options: #{names}")
    end
  end

  defp value(nil), do: "unavailable"
  defp value(value), do: to_string(value)
end
