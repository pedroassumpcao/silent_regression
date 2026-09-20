defmodule SilentRegression.Providers.FakeAnthropic do
  @moduledoc """
  Deterministic, content-free Anthropic adapter used by automated tests.
  """

  @behaviour SilentRegression.Providers.Adapter

  alias SilentRegression.Providers.{
    CompletionRequest,
    CompletionResult,
    CredentialValidation,
    Failure
  }

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

  @impl true
  def complete_once(secret, %CompletionRequest{} = request, _options) do
    fake_completion(:anthropic, secret, request)
  end

  defp fake_completion(_provider, "sk-test-authentication-error", request) do
    {:error,
     %Failure{
       category: :authentication,
       message: "The fake adapter rejected the credential.",
       requested_model: request.requested_model,
       attempts: 1,
       latency_ms: 1
     }}
  end

  defp fake_completion(provider, secret, request) do
    request_text = Jason.encode!(request.request_artifact)

    cond do
      String.contains?(request_text, "[fake:retry-once]") and request.attempt_number == 1 ->
        {:error,
         %Failure{
           category: :rate_limited,
           message: "The fake adapter was rate limited.",
           requested_model: request.requested_model,
           attempts: 1,
           retryable: true,
           latency_ms: 1
         }}

      String.contains?(request_text, "[fake:provider-failure]") ->
        {:error,
         %Failure{
           category: :provider_unavailable,
           message: "The fake provider is unavailable.",
           requested_model: request.requested_model,
           attempts: 1,
           retryable: false,
           latency_ms: 1
         }}

      true ->
        output_text =
          if secret == "sk-test-output-maybe" or
               String.contains?(request_text, "[fake:output=maybe]"),
             do: "maybe",
             else: "approved"

        returned_model =
          if String.contains?(request_text, "[fake:model-mismatch]"),
            do: "#{request.requested_model}-unexpected",
            else: request.requested_model

        completion_state =
          if String.contains?(request_text, "[fake:incomplete]"),
            do: :incomplete,
            else: :complete

        {:ok,
         %CompletionResult{
           provider: provider,
           requested_model: request.requested_model,
           returned_model: returned_model,
           output_text: output_text,
           request_id: "fake_anthropic_#{request.client_request_id}",
           completion_state: completion_state,
           input_tokens: 10,
           output_tokens: 1,
           latency_ms: 1,
           finish_reason: "end_turn",
           captured_at: DateTime.utc_now(),
           metadata: %{"client_request_id" => request.client_request_id}
         }}
    end
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
