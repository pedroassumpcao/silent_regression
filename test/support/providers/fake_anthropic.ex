defmodule SilentRegression.Providers.FakeAnthropic do
  @moduledoc """
  Deterministic, content-free Anthropic adapter used by automated tests.
  """

  @behaviour SilentRegression.Providers.Adapter

  alias SilentRegression.Providers.{CredentialValidation, Failure}

  @impl true
  def request_provenance do
    %{
      api_endpoint: "https://anthropic.invalid/v1/models",
      api_version: "test",
      http_method: "GET"
    }
  end

  @impl true
  def validate_credential("sk-test-authentication-error", options) do
    {:error, failure(:authentication, "fake_authentication_request", options)}
  end

  def validate_credential("sk-test-rate-limited", options) do
    {:error, failure(:rate_limited, "fake_rate_limit_request", options)}
  end

  def validate_credential(_secret, options) do
    model = Keyword.get(options, :model)

    {:ok,
     %CredentialValidation{
       provider: :anthropic,
       requested_model: model,
       returned_model: model || "fake-anthropic-model",
       request_id: "fake_anthropic_validation_request",
       attempts: 1
     }}
  end

  defp failure(category, request_id, options) do
    %Failure{
      category: category,
      message: "The fake Anthropic adapter rejected validation.",
      request_id: request_id,
      requested_model: Keyword.get(options, :model),
      attempts: 1
    }
  end
end
