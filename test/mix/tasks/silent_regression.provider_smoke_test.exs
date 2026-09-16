defmodule Mix.Tasks.SilentRegression.ProviderSmokeTest do
  use SilentRegression.DataCase, async: false

  import ExUnit.CaptureIO
  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.PilotSmoke
  alias SilentRegression.ProviderCredentials

  setup do
    Mix.Task.reenable("silent_regression.provider_smoke")
    :ok
  end

  test "previews the exact one-call envelope without invoking the provider" do
    {scope, credential} = validated_credential(:openai, "gpt-5.6-luna")

    output =
      capture_io(fn ->
        Mix.Tasks.SilentRegression.ProviderSmoke.run(
          preview_args(scope.workspace.slug, credential.id, :openai, "gpt-5.6-luna")
        )
      end)

    assert output =~ "Provider smoke preview"
    assert output =~ "Provider calls: 1 planned, 1 maximum"
    assert output =~ "Retries: 0"
    assert output =~ "System prompt: Return exactly the single lowercase word approved."
    assert output =~ "User prompt: Reply with exactly approved."
    assert output =~ "Preview only: no provider request was made."
    refute output =~ "sk-test-provider-credential-sentinel"
  end

  test "executes only when every confirmation matches the current preview" do
    {scope, credential} = validated_credential(:anthropic, "claude-haiku-4-5-20251001")

    {:ok, preview} =
      PilotSmoke.preview(
        workspace_slug: scope.workspace.slug,
        credential_id: credential.id,
        provider: :anthropic,
        model: "claude-haiku-4-5-20251001"
      )

    output =
      capture_io(fn ->
        Mix.Tasks.SilentRegression.ProviderSmoke.run(
          preview_args(
            scope.workspace.slug,
            credential.id,
            :anthropic,
            "claude-haiku-4-5-20251001"
          ) ++
            [
              "--execute",
              "--confirm-provider",
              "anthropic",
              "--confirm-model",
              "claude-haiku-4-5-20251001",
              "--confirm-max-calls",
              "1",
              "--confirm-fingerprint",
              preview.preview_fingerprint
            ]
        )
      end)

    assert output =~ "Provider smoke passed"
    assert output =~ "Actual calls: 1"
    assert output =~ "Contract: pass"
    refute output =~ "sk-test-provider-credential-sentinel"
  end

  test "rejects a stale or mistyped execution confirmation before any call" do
    {scope, credential} = validated_credential(:openai, "gpt-5.6-luna")

    assert_raise Mix.Error, ~r/confirmation does not match/, fn ->
      capture_io(fn ->
        Mix.Tasks.SilentRegression.ProviderSmoke.run(
          preview_args(scope.workspace.slug, credential.id, :openai, "gpt-5.6-luna") ++
            [
              "--execute",
              "--confirm-provider",
              "openai",
              "--confirm-model",
              "gpt-5.6-luna",
              "--confirm-max-calls",
              "2",
              "--confirm-fingerprint",
              String.duplicate("0", 64)
            ]
        )
      end)
    end
  end

  defp validated_credential(provider, model) do
    scope = workspace_scope_fixture()

    credential =
      provider_credential_fixture(scope, %{
        provider: provider,
        label: "#{provider} smoke credential"
      })

    assert {:ok, validated} =
             ProviderCredentials.validate_credential(scope, credential.id, %{model: model})

    {scope, validated}
  end

  defp preview_args(workspace_slug, credential_id, provider, model) do
    [
      "--workspace-slug",
      workspace_slug,
      "--provider",
      Atom.to_string(provider),
      "--model",
      model,
      "--credential-id",
      credential_id
    ]
  end
end
