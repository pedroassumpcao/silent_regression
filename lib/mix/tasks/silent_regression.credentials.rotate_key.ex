defmodule Mix.Tasks.SilentRegression.Credentials.RotateKey do
  @shortdoc "Previews or executes provider-credential key rotation"

  @moduledoc """
  Inventories encrypted provider credentials without exposing plaintext:

      mix silent_regression.credentials.rotate_key

  After adding a new default cipher and retaining the previous cipher in the
  runtime keyring, re-encrypt every row with an exact active-tag confirmation:

      mix silent_regression.credentials.rotate_key \
        --execute \
        --confirm-active-tag AES.GCM.V2

  Do not remove the retired key until this command reports every row under the
  active tag and all backups encrypted under the retired key have expired.
  """

  use Mix.Task

  alias SilentRegression.ProviderCredentials.KeyRotation

  @switches [execute: :boolean, confirm_active_tag: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Unknown arguments. Run `mix help silent_regression.credentials.rotate_key`.")
    end

    before = KeyRotation.inventory()
    print_inventory("Credential key inventory", before)

    if opts[:execute] do
      confirm_active_tag!(opts[:confirm_active_tag], before.active_tag)

      case KeyRotation.migrate_to_active_key() do
        {:ok, after_rotation} ->
          print_inventory("Credential key rotation complete", after_rotation)

        {:error, reason} ->
          Mix.raise("Credential key rotation verification failed: #{inspect(reason)}")
      end
    else
      Mix.shell().info("No data changed. Add --execute and --confirm-active-tag to rotate.")
    end
  end

  defp confirm_active_tag!(active_tag, active_tag), do: :ok

  defp confirm_active_tag!(_supplied, active_tag) do
    Mix.raise("--confirm-active-tag must exactly match #{active_tag}")
  end

  defp print_inventory(title, inventory) do
    Mix.shell().info(title)
    Mix.shell().info("Active tag: #{inventory.active_tag}")
    Mix.shell().info("Rows: #{inventory.total_count}")
    Mix.shell().info("Decryptable: #{inventory.decryptable_count}")
    Mix.shell().info("Unreadable headers: #{inventory.unreadable_count}")

    inventory.tag_counts
    |> Enum.sort()
    |> Enum.each(fn {tag, count} -> Mix.shell().info("#{tag}: #{count}") end)
  end
end
