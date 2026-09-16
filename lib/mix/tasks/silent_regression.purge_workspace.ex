defmodule Mix.Tasks.SilentRegression.PurgeWorkspace do
  @shortdoc "Previews or executes a due workspace purge"

  @moduledoc """
  Previews a closed workspace's purge status without changing data:

      mix silent_regression.purge_workspace \
        --workspace-slug acme-ai \
        --confirm-slug acme-ai

  Add `--execute` only after verifying the preview. Execution is irreversible
  and succeeds only when the persisted purge deadline is due.
  """

  use Mix.Task

  alias SilentRegression.WorkspaceLifecycle

  @switches [workspace_slug: :string, confirm_slug: :string, execute: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse!(args)
    slug = require_option!(opts, :workspace_slug)
    confirm_slug = require_option!(opts, :confirm_slug)

    if slug != confirm_slug do
      Mix.raise("--confirm-slug must exactly match --workspace-slug")
    end

    if opts[:execute] do
      execute!(slug)
    else
      preview!(slug)
    end
  end

  defp preview!(slug) do
    case WorkspaceLifecycle.purge_preview(slug) do
      {:ok, preview} ->
        Mix.shell().info("Workspace purge preview")
        Mix.shell().info("Workspace slug: #{preview.workspace_slug}")
        Mix.shell().info("Status: #{preview.status}")
        Mix.shell().info("Request type: #{preview.request_type}")
        Mix.shell().info("Purge due: #{format_datetime(preview.purge_due_at)}")
        Mix.shell().info("Due now: #{preview.due?}")
        Mix.shell().info("No data changed. Add --execute to perform an eligible purge.")

      {:error, reason} ->
        Mix.raise("Could not preview workspace purge: #{inspect(reason)}")
    end
  end

  defp execute!(slug) do
    case WorkspaceLifecycle.operator_purge_due_workspace(slug) do
      {:ok, receipt} ->
        Mix.shell().info("Workspace purge completed")
        Mix.shell().info("Deletion receipt: #{receipt.request_id}")
        Mix.shell().info("Completed: #{DateTime.to_iso8601(receipt.completed_at)}")

      {:error, reason} ->
        Mix.raise("Workspace purge refused: #{inspect(reason)}")
    end
  end

  defp parse!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Unknown arguments. Run `mix help silent_regression.purge_workspace`.")
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

  defp format_datetime(nil), do: "not scheduled"
  defp format_datetime(datetime), do: DateTime.to_iso8601(datetime)
end
