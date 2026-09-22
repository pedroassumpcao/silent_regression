# Manual runner, not an ExUnit test. See docs/monitor-setup/usability/README.md.
if Mix.env() != :test, do: raise("Usability sandbox requires MIX_ENV=test.")

participant =
  case System.argv() do
    [participant] -> participant
    _ -> raise "Supply exactly one pseudonymous session ID, such as rehearsal01 or p01."
  end

SilentRegression.UsabilityStudy.configure!(participant)
Mix.Task.run("ecto.create", ["--quiet", "-r", "SilentRegression.Repo"])
Mix.Task.run("ecto.migrate", ["--quiet", "-r", "SilentRegression.Repo"])
{:ok, _} = Application.ensure_all_started(:silent_regression)
Logger.configure(level: :warning)
scope = SilentRegression.UsabilityStudy.seed!(participant)
IO.puts(SilentRegression.UsabilityStudy.instructions(scope))
