defmodule SilentRegression.Providers do
  @moduledoc """
  Registry-backed boundary for product provider integrations.

  Product contexts depend on this module and the adapter behaviour, not on Req
  or a provider-specific response shape.
  """

  alias SilentRegression.Providers.{
    CompletionRequest,
    CompletionResult,
    CredentialValidation,
    Failure
  }

  def request_provenance(provider) when provider in [:openai, :anthropic] do
    with {:ok, adapter} <- adapter_for(provider) do
      {:ok, adapter.request_provenance()}
    end
  end

  def request_provenance(_provider), do: {:error, :unsupported_provider}

  def validate_credential(provider, secret, options \\ [])

  def validate_credential(provider, secret, options)
      when provider in [:openai, :anthropic] and is_binary(secret) and is_list(options) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter
      |> safe_validate(secret, options)
      |> normalize_adapter_result(provider)
    end
  end

  def validate_credential(_provider, _secret, _options) do
    {:error,
     %Failure{
       category: :provider,
       message: "The provider configuration is unavailable.",
       attempts: 1
     }}
  end

  def complete_once(provider, secret, request, options \\ [])

  def complete_once(provider, secret, %CompletionRequest{} = request, options)
      when provider in [:openai, :anthropic] and is_binary(secret) and is_list(options) do
    with {:ok, adapter} <- adapter_for(provider) do
      adapter
      |> safe_complete(secret, request, options)
      |> normalize_completion_result(provider)
    end
  end

  def complete_once(_provider, _secret, _request, _options) do
    {:error,
     %Failure{
       category: :invalid_request,
       message: "The provider completion request is invalid.",
       attempts: 1
     }}
  end

  defp safe_validate(adapter, secret, options) do
    adapter.validate_credential(secret, options)
  rescue
    _error ->
      {:error,
       %Failure{
         category: :provider,
         message: "The provider adapter could not validate the credential.",
         attempts: 1
       }}
  end

  defp safe_complete(adapter, secret, request, options) do
    adapter.complete_once(secret, request, options)
  rescue
    _error ->
      {:error,
       %Failure{
         category: :provider_unavailable,
         message: "The provider adapter could not complete the request.",
         requested_model: request.requested_model,
         attempts: 1
       }}
  end

  defp normalize_adapter_result(
         {:ok, %CredentialValidation{provider: provider} = result},
         provider
       ),
       do: {:ok, result}

  defp normalize_adapter_result({:error, %Failure{} = failure}, _provider),
    do: {:error, failure}

  defp normalize_adapter_result(_result, _provider) do
    {:error,
     %Failure{
       category: :malformed_response,
       message: "The provider adapter returned an invalid validation result.",
       attempts: 1
     }}
  end

  defp normalize_completion_result(
         {:ok, %CompletionResult{provider: provider} = result},
         provider
       ),
       do: {:ok, result}

  defp normalize_completion_result({:error, %Failure{} = failure}, _provider),
    do: {:error, failure}

  defp normalize_completion_result(_result, _provider) do
    {:error,
     %Failure{
       category: :malformed_response,
       message: "The provider adapter returned an invalid completion result.",
       attempts: 1
     }}
  end

  defp adapter_for(provider) do
    :silent_regression
    |> Application.fetch_env!(:provider_adapters)
    |> Keyword.fetch(provider)
    |> case do
      {:ok, adapter} ->
        {:ok, adapter}

      :error ->
        {:error,
         %Failure{
           category: :provider,
           message: "The provider configuration is unavailable.",
           attempts: 1
         }}
    end
  end
end
