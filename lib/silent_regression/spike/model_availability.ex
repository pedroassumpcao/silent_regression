defmodule SilentRegression.Spike.ModelAvailability do
  @moduledoc """
  Checks that the authenticated account can retrieve an explicitly requested model.

  This check runs immediately before live generation and is counted as one
  provider request. It never retries or substitutes a different model. Tests
  may inject `Req.Test` through the same restricted request options accepted by
  the provider clients.
  """

  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Validation

  @anthropic_api_version "2023-06-01"
  @allowed_options [:api_key, :environment, :req_options]
  @allowed_req_options [
    :adapter,
    :connect_options,
    :finch,
    :plug,
    :pool_timeout,
    :receive_timeout,
    :request_timeout
  ]

  @type result :: %{required(String.t()) => term()}

  @doc """
  Retrieves `model` using the provider's authenticated Models endpoint.

  A successful response must identify the exact requested model. Every return
  value is safe to persist and never contains the API key.
  """
  @spec check(module(), String.t(), keyword()) ::
          {:ok, result()} | {:error, Provider.error()}
  def check(provider, model, options \\ []) do
    with :ok <- validate_options(options),
         {:ok, provider_id} <- provider_id(provider),
         :ok <- validate_model(model),
         {:ok, config} <- build_config(provider_id, options),
         {:ok, response} <- request(provider_id, model, config),
         {:ok, returned_model} <- validate_response(response, model) do
      {:ok,
       %{
         "provider" => provider_id,
         "requested_model" => model,
         "returned_model" => returned_model,
         "request_id" => request_id(provider_id, response),
         "api_endpoint" => endpoint(provider_id, model),
         "api_version" => api_version(provider_id),
         "http_method" => "GET",
         "attempts" => 1
       }}
    end
  end

  defp validate_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)
      unsupported = keys -- @allowed_options

      cond do
        Enum.uniq(keys) != keys ->
          configuration_error("Model availability options contain duplicate keys", %{
            "field" => "options"
          })

        unsupported != [] ->
          configuration_error("Model availability options contain unsupported keys", %{
            "unsupported_options" => Enum.map(unsupported, &Atom.to_string/1)
          })

        true ->
          :ok
      end
    else
      configuration_error("Model availability options must be a keyword list", %{
        "field" => "options"
      })
    end
  end

  defp validate_options(_options) do
    configuration_error("Model availability options must be a keyword list", %{
      "field" => "options"
    })
  end

  defp provider_id(provider) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :id, 0) do
      case provider.id() do
        provider_id when provider_id in ["openai", "anthropic"] -> {:ok, provider_id}
        provider_id -> unsupported_provider(provider_id)
      end
    else
      unsupported_provider(nil)
    end
  rescue
    _error -> unsupported_provider(nil)
  end

  defp provider_id(_provider), do: unsupported_provider(nil)

  defp unsupported_provider(provider_id) do
    {:error,
     Provider.error(
       :unsupported_provider,
       "Model availability is not supported for this provider",
       details: %{"provider" => provider_id}
     )}
  end

  defp validate_model(model) when is_binary(model) do
    if String.valid?(model) and String.trim(model) != "" do
      :ok
    else
      configuration_error("Model must be a non-empty string", %{"field" => "model"})
    end
  end

  defp validate_model(_model) do
    configuration_error("Model must be a non-empty string", %{"field" => "model"})
  end

  defp build_config(provider_id, options) do
    with {:ok, environment} <- environment(options),
         {:ok, api_key} <- api_key(provider_id, options, environment),
         {:ok, req_options} <- req_options(options) do
      {:ok, %{api_key: api_key, req_options: req_options}}
    end
  end

  defp environment(options) do
    environment = Keyword.get_lazy(options, :environment, &System.get_env/0)

    if is_map(environment) do
      {:ok, environment}
    else
      configuration_error("Model availability environment must be a map", %{
        "field" => "environment"
      })
    end
  end

  defp api_key(provider_id, options, environment) do
    env_var = credential_env_var(provider_id)
    value = Keyword.get(options, :api_key, environment[env_var])

    if is_binary(value) and String.valid?(value) and String.trim(value) != "" do
      {:ok, value}
    else
      configuration_error("Required provider credential is missing", %{
        "field" => "environment",
        "env_var" => env_var
      })
    end
  end

  defp credential_env_var("openai"), do: "OPENAI_API_KEY"
  defp credential_env_var("anthropic"), do: "ANTHROPIC_API_KEY"

  defp req_options(options) do
    req_options = Keyword.get(options, :req_options, [])
    keys = if Keyword.keyword?(req_options), do: Keyword.keys(req_options), else: []
    unsupported = keys -- @allowed_req_options

    cond do
      not Keyword.keyword?(req_options) ->
        configuration_error("Model availability req_options must be a keyword list", %{
          "field" => "req_options"
        })

      Enum.uniq(keys) != keys ->
        configuration_error("Model availability req_options contain duplicate keys", %{
          "field" => "req_options"
        })

      unsupported != [] ->
        configuration_error("Model availability req_options contain unsafe keys", %{
          "unsupported_options" => Enum.map(unsupported, &Atom.to_string/1)
        })

      true ->
        {:ok, req_options}
    end
  end

  defp request(provider_id, model, config) do
    request_options =
      config.req_options
      |> Keyword.put(:method, :get)
      |> Keyword.put(:url, endpoint(provider_id, model))
      |> Keyword.put(:headers, headers(provider_id, config.api_key))
      |> Keyword.put(:retry, false)

    case safe_request(request_options) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Provider.error(:model_unavailable, "The requested model could not be retrieved",
           details: %{
             "attempts" => 1,
             "provider" => provider_id,
             "requested_model" => model,
             "status" => status,
             "response_body" => safe_json(body)
           }
         )}

      {:error, exception} ->
        {:error,
         Provider.error(
           :model_availability_request_failed,
           "The model availability request failed",
           details: %{
             "attempts" => 1,
             "provider" => provider_id,
             "requested_model" => model,
             "reason" => exception_reason(exception)
           }
         )}
    end
  end

  defp safe_request(request_options) do
    Req.request(request_options)
  rescue
    error in Jason.DecodeError -> {:error, error}
  end

  defp endpoint("openai", model),
    do: "https://api.openai.com/v1/models/#{URI.encode(model)}"

  defp endpoint("anthropic", model),
    do: "https://api.anthropic.com/v1/models/#{URI.encode(model)}"

  defp api_version("openai"), do: "v1"
  defp api_version("anthropic"), do: @anthropic_api_version

  defp headers("openai", api_key) do
    [{"accept", "application/json"}, {"authorization", "Bearer #{api_key}"}]
  end

  defp headers("anthropic", api_key) do
    [
      {"accept", "application/json"},
      {"anthropic-version", @anthropic_api_version},
      {"x-api-key", api_key}
    ]
  end

  defp validate_response(%Req.Response{body: %{"id" => model}}, requested_model)
       when model == requested_model,
       do: {:ok, model}

  defp validate_response(%Req.Response{body: body}, requested_model) do
    {:error,
     Provider.error(:invalid_model_response, "The Models endpoint returned an unexpected model",
       details: %{
         "attempts" => 1,
         "requested_model" => requested_model,
         "returned_model" => if(is_map(body), do: body["id"], else: nil)
       }
     )}
  end

  defp request_id("openai", response), do: first_header(response, "x-request-id")
  defp request_id("anthropic", response), do: first_header(response, "request-id")

  defp first_header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp safe_json(value) do
    if Validation.json_value?(value), do: value, else: inspect(value)
  end

  defp exception_reason(%{reason: reason}), do: inspect(reason)
  defp exception_reason(exception), do: Exception.message(exception)

  defp configuration_error(message, details) do
    {:error, Provider.error(:configuration_error, message, details: details)}
  end
end
