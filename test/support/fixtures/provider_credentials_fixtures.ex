defmodule SilentRegression.ProviderCredentialsFixtures do
  @moduledoc """
  Test helpers for encrypted workspace provider credentials.
  """

  alias SilentRegression.ProviderCredentials

  def valid_provider_credential_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      provider: :openai,
      label: "Primary OpenAI",
      secret: "sk-test-provider-credential-sentinel"
    })
  end

  def provider_credential_fixture(scope, attrs \\ %{}) do
    {:ok, credential} =
      ProviderCredentials.create_credential(scope, valid_provider_credential_attributes(attrs))

    credential
  end
end
