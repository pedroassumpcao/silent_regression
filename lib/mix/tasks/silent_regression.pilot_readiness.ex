defmodule Mix.Tasks.SilentRegression.PilotReadiness do
  @shortdoc "Checks the hosted-pilot invitation gate"

  @moduledoc """
  Prints the explicit invitation switch, operational health, and each required
  drill without exposing evidence references or operator identities:

      mix silent_regression.pilot_readiness
  """

  use Mix.Task

  alias SilentRegression.PilotReadiness

  @impl Mix.Task
  def run(args) do
    if args != [], do: Mix.raise("This task accepts no arguments.")
    Mix.Task.run("app.start")
    readiness = PilotReadiness.status()

    Mix.shell().info(
      "Pilot invitation readiness: #{if(readiness.ready, do: "ready", else: "blocked")}"
    )

    Mix.shell().info("Environment: #{readiness.environment}")
    Mix.shell().info("Release: #{readiness.release_sha}")
    Mix.shell().info("Invitation switch: #{readiness.invitations_enabled}")
    Mix.shell().info("Operational health: #{readiness.operational_health}")

    Enum.each(readiness.drills, fn drill ->
      Mix.shell().info(
        "#{drill.kind}: #{if(drill.current, do: "current", else: "missing-or-stale")}"
      )
    end)

    unless readiness.ready, do: Mix.raise("Pilot invitation gate is blocked")
  end
end
