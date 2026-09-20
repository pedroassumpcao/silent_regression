defmodule SilentRegression.Providers.OpenAI do
  @moduledoc """
  Credential validation through OpenAI's Models API.

  Validation does not generate content or retain response bodies. Req's retry
  step is disabled so this operation is always exactly one provider request.
  """

  @behaviour SilentRegression.Providers.Adapter

  alias SilentRegression.Providers.{CompletionAdapter, CompletionRequest, ModelValidation}

  @endpoint "https://api.openai.com/v1/models"

  @impl true
  def request_provenance do
    %{api_endpoint: @endpoint, api_version: "v1", http_method: "GET"}
  end

  @impl true
  def validate_credential(secret, options) when is_binary(secret) do
    with {:ok, config} <- ModelValidation.options(options) do
      request_options =
        config.req_options
        |> Keyword.put(:method, :get)
        |> Keyword.put(:url, ModelValidation.endpoint(@endpoint, config.model))
        |> Keyword.put(:auth, {:bearer, secret})
        |> Keyword.put(:headers, [{"accept", "application/json"}])
        |> Keyword.put(:retry, false)

      ModelValidation.normalize(:openai, safe_request(request_options), config.model)
    end
  end

  def validate_credential(_secret, _options),
    do: ModelValidation.request_exception(:openai, nil)

  @impl true
  def complete_once(secret, %CompletionRequest{} = request, options) do
    CompletionAdapter.complete_once(:openai, secret, request, options)
  end

  defp safe_request(request_options) do
    Req.request(request_options)
  rescue
    _error in Jason.DecodeError -> {:error, :decode_error}
    _error -> {:error, :request_exception}
  end
end
