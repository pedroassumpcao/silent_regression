defmodule Mix.Tasks.SilentRegression.ProviderSmoke do
  @shortdoc "Previews or runs one fixed-content provider transport smoke call"

  @moduledoc """
  Previews a fixed, one-case, one-sample provider smoke contract without making
  a provider request:

      mix silent_regression.provider_smoke \
        --workspace-slug your-workspace \
        --provider anthropic \
        --model claude-haiku-4-5-20251001 \
        --credential-id 00000000-0000-0000-0000-000000000000

  Execution makes exactly one completion call with no retry and requires exact
  confirmation of the previewed provider, model, maximum call count, and
  fingerprint:

      mix silent_regression.provider_smoke ... \
        --execute \
        --confirm-provider anthropic \
        --confirm-model claude-haiku-4-5-20251001 \
        --confirm-max-calls 1 \
        --confirm-fingerprint PREVIEW_FINGERPRINT

  Run execution only after a fresh, provider-specific user authorization. The
  task never prints the credential or captured output.
  """

  use Mix.Task

  alias SilentRegression.PilotSmoke

  @switches [
    workspace_slug: :string,
    provider: :string,
    model: :string,
    credential_id: :string,
    execute: :boolean,
    confirm_provider: :string,
    confirm_model: :string,
    confirm_max_calls: :integer,
    confirm_fingerprint: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise(
        "Unknown provider-smoke arguments. Run `mix help silent_regression.provider_smoke`."
      )
    end

    preview_options =
      Keyword.take(opts, [:workspace_slug, :provider, :model, :credential_id])

    with {:ok, preview} <- PilotSmoke.preview(preview_options) do
      print_preview(preview)

      if Keyword.get(opts, :execute, false) do
        confirm_execution!(opts, preview)
        execute!(preview)
      else
        Mix.shell().info("Preview only: no provider request was made.")
      end
    else
      {:error, reason} -> Mix.raise("Provider smoke preview failed: #{format_reason(reason)}")
    end
  end

  defp print_preview(preview) do
    Mix.shell().info("Provider smoke preview")
    Mix.shell().info("Workspace: #{preview.workspace_slug}")
    Mix.shell().info("Provider: #{preview.provider}")
    Mix.shell().info("Model: #{preview.model}")

    Mix.shell().info(
      "Credential: #{preview.credential_label} (#{preview.credential_id}, ending #{preview.credential_suffix})"
    )

    Mix.shell().info("Configuration: text response, 16 maximum output tokens")
    Mix.shell().info("Case: #{preview.case_key} (1 case, 1 sample)")
    Mix.shell().info("System prompt: #{preview.system_prompt}")
    Mix.shell().info("Frozen context: #{preview.context}")
    Mix.shell().info("User prompt: #{preview.user_prompt}")
    Mix.shell().info("Contract: normalized output must equal approved")
    Mix.shell().info("Retries: #{preview.retry_limit}")
    Mix.shell().info("Provider calls: 1 planned, 1 maximum")
    Mix.shell().info("Preview fingerprint: #{preview.preview_fingerprint}")
  end

  defp confirm_execution!(opts, preview) do
    confirmations = %{
      provider: Keyword.get(opts, :confirm_provider),
      model: Keyword.get(opts, :confirm_model),
      maximum_call_count: Keyword.get(opts, :confirm_max_calls),
      fingerprint: Keyword.get(opts, :confirm_fingerprint)
    }

    expected = %{
      provider: Atom.to_string(preview.provider),
      model: preview.model,
      maximum_call_count: preview.maximum_call_count,
      fingerprint: preview.preview_fingerprint
    }

    if confirmations != expected do
      Mix.raise(
        "Execution confirmation does not match the current preview. No provider request was made."
      )
    end
  end

  defp execute!(preview) do
    case PilotSmoke.execute(preview) do
      {:ok, summary} ->
        Mix.shell().info("Provider smoke passed")
        Mix.shell().info("Actual calls: #{summary.actual_call_count}")
        Mix.shell().info("Attempts: #{summary.attempts}")

        Mix.shell().info(
          "Model: #{summary.requested_model} -> #{summary.returned_model} (match: #{summary.model_match})"
        )

        Mix.shell().info("Completion: #{summary.completion_state}")
        Mix.shell().info("Contract: #{summary.contract_status}")

        Mix.shell().info(
          "Usage: #{summary.input_tokens} input, #{summary.output_tokens} output tokens"
        )

        Mix.shell().info("Latency: #{summary.latency_ms} ms")
        Mix.shell().info("Output bytes: #{summary.output_bytes}")
        Mix.shell().info("Provider request ID: #{summary.request_id || "not returned"}")

      {:error, summary} when is_map(summary) ->
        Mix.shell().error("Provider smoke failed")
        Mix.shell().error("Safe result: #{inspect(summary)}")
        Mix.raise("The provider smoke did not satisfy the fixed contract.")

      {:error, reason} ->
        Mix.raise("Provider smoke execution failed: #{format_reason(reason)}")
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
