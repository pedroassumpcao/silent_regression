defmodule Mix.Tasks.SilentRegression.OpsCheck do
  @shortdoc "Checks content-free hosted operational health"

  @moduledoc """
  Prints queue, scheduler, provider-outcome, notification, and purge health:

      mix silent_regression.ops_check
      mix silent_regression.ops_check --format json

  The task exits unsuccessfully for degraded or critical state so an external
  scheduler can alert. Use `--allow-degraded` only for an explicitly accepted
  maintenance condition; critical state always fails.
  """

  use Mix.Task

  alias SilentRegression.OperationalHealth

  @switches [format: :string, allow_degraded: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse!(args)
    snapshot = OperationalHealth.snapshot()
    print(snapshot, opts[:format] || "text")

    if snapshot.status == :critical or
         (snapshot.status == :degraded and not opts[:allow_degraded]) do
      Mix.raise("Operational health is #{snapshot.status}")
    end
  end

  defp parse!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] or
         (opts[:format] && opts[:format] not in ["text", "json"]) do
      Mix.raise("Use --format text|json and optional --allow-degraded.")
    end

    opts
  end

  defp print(snapshot, "json") do
    Mix.shell().info(Jason.encode!(snapshot))
  end

  defp print(snapshot, "text") do
    Mix.shell().info("Operational health: #{snapshot.status}")
    Mix.shell().info("Checked: #{DateTime.to_iso8601(snapshot.checked_at)}")

    Enum.each(snapshot.checks, fn check ->
      Mix.shell().info("#{check.name}: #{check.status} #{inspect(check.measurements)}")
    end)
  end
end
