defmodule SilentRegression.Providers.Anthropic do
  @moduledoc """
  Credential validation through Anthropic's Models API.

  Validation does not generate content or retain response bodies. Req's retry
  step is disabled so this operation is always exactly one provider request.
  """

  @behaviour SilentRegression.Providers.Adapter

  alias SilentRegression.Providers.ModelValidation

  @endpoint "https://api.anthropic.com/v1/models"
  @api_version "2023-06-01"

  @impl true
  def request_provenance do
    %{api_endpoint: @endpoint, api_version: @api_version, http_method: "GET"}
  end

  @impl true
  def validate_credential(secret, options) when is_binary(secret) do
    with {:ok, config} <- ModelValidation.options(options) do
      request_options =
        config.req_options
        |> Keyword.put(:method, :get)
        |> Keyword.put(:url, ModelValidation.endpoint(@endpoint, config.model))
        |> Keyword.put(:headers, request_headers(secret))
        |> Keyword.put(:retry, false)

      ModelValidation.normalize(:anthropic, safe_request(request_options), config.model)
    end
  end

  def validate_credential(_secret, _options),
    do: ModelValidation.request_exception(:anthropic, nil)

  defp request_headers(secret) do
    [
      {"accept", "application/json"},
      {"anthropic-version", @api_version},
      {"x-api-key", secret}
    ]
  end

  defp safe_request(request_options) do
    Req.request(request_options)
  rescue
    _error in Jason.DecodeError -> {:error, :decode_error}
    _error -> {:error, :request_exception}
  end
end
