defmodule SilentRegression.Providers.FakeOpenAI do
  @moduledoc """
  Deterministic, content-free OpenAI adapter used by automated tests.
  """

  @behaviour SilentRegression.Providers.Adapter

  alias SilentRegression.Providers.{CredentialValidation, Failure}

  @impl true
  def request_provenance do
    %{api_endpoint: "https://openai.invalid/v1/models", api_version: "test", http_method: "GET"}
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
       provider: :openai,
       requested_model: model,
       returned_model: model || "fake-openai-model",
       request_id: "fake_openai_validation_request",
       attempts: 1
     }}
  end

  defp failure(category, request_id, options) do
    %Failure{
      category: category,
      message: "The fake OpenAI adapter rejected validation.",
      request_id: request_id,
      requested_model: Keyword.get(options, :model),
      attempts: 1
    }
  end
end
