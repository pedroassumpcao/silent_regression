defmodule Mix.Tasks.SilentRegression.ReopenWorkspace do
  @shortdoc "Reopens an ordinarily closed workspace during retention"

  @moduledoc """
  Reopens a workspace during its ordinary 30-day closure-retention window:

      mix silent_regression.reopen_workspace \
        --workspace-slug acme-ai \
        --confirm-slug acme-ai \
        --actor-email owner@acme.example \
        --execute

  Explicit deletion requests cannot be reopened. Credentials remain revoked
  and monitors remain paused so the owner must deliberately reconfigure them.
  """

  use Mix.Task

  alias SilentRegression.WorkspaceLifecycle

  @switches [
    workspace_slug: :string,
    confirm_slug: :string,
    actor_email: :string,
    execute: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse!(args)
    slug = require_option!(opts, :workspace_slug)
    confirm_slug = require_option!(opts, :confirm_slug)
    actor_email = require_option!(opts, :actor_email)

    if slug != confirm_slug do
      Mix.raise("--confirm-slug must exactly match --workspace-slug")
    end

    unless opts[:execute] do
      Mix.raise("Reopening changes workspace access. Re-run with --execute after verification.")
    end

    case WorkspaceLifecycle.operator_reopen(slug, actor_email) do
      {:ok, workspace} ->
        Mix.shell().info("Workspace reopened: #{workspace.slug}")
        Mix.shell().info("Credentials remain revoked and monitors remain paused.")

      {:error, reason} ->
        Mix.raise("Workspace reopen refused: #{inspect(reason)}")
    end
  end

  defp parse!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Unknown arguments. Run `mix help silent_regression.reopen_workspace`.")
    end

    opts
  end

  defp require_option!(opts, key) do
    case opts[key] do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        Mix.raise(
          "Missing required option --#{key |> Atom.to_string() |> String.replace("_", "-")}"
        )
    end
  end
end
