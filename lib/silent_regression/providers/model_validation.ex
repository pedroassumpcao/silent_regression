defmodule SilentRegression.Providers.ModelValidation do
  @moduledoc false

  alias SilentRegression.Providers.{CredentialValidation, Failure}

  @allowed_req_options [
    :adapter,
    :connect_options,
    :finch,
    :plug,
    :pool_timeout,
    :receive_timeout,
    :request_timeout
  ]

  def options(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- [:model, :req_options],
         {:ok, model} <- optional_model(Keyword.get(options, :model)),
         {:ok, req_options} <- req_options(Keyword.get(options, :req_options, [])) do
      {:ok, %{model: model, req_options: req_options}}
    else
      _other -> {:error, failure(:provider, "The credential validation options are invalid.")}
    end
  end

  def options(_options),
    do: {:error, failure(:provider, "The credential validation options are invalid.")}

  def endpoint(base_endpoint, nil), do: base_endpoint

  def endpoint(base_endpoint, model) do
    encoded_model = URI.encode(model, &URI.char_unreserved?/1)
    base_endpoint <> "/" <> encoded_model
  end

  def normalize(provider, {:ok, %Req.Response{status: status} = response}, requested_model)
      when status >= 200 and status < 300 do
    with {:ok, returned_model} <- returned_model(response.body, requested_model) do
      {:ok,
       %CredentialValidation{
         provider: provider,
         requested_model: requested_model,
         returned_model: returned_model,
         request_id: request_id(response),
         attempts: 1
       }}
    else
      {:error, :malformed_response} ->
        {:error,
         failure(
           :malformed_response,
           "The provider returned an invalid credential-validation response.",
           request_id(response),
           requested_model
         )}
    end
  end

  def normalize(provider, {:ok, %Req.Response{} = response}, requested_model) do
    category = response.status |> failure_category(requested_model)

    {:error,
     failure(
       category,
       failure_message(provider, category),
       request_id(response),
       requested_model
     )}
  end

  def normalize(provider, {:error, %Jason.DecodeError{}}, requested_model) do
    malformed_decode_failure(provider, requested_model)
  end

  def normalize(provider, {:error, :decode_error}, requested_model) do
    malformed_decode_failure(provider, requested_model)
  end

  def normalize(provider, {:error, _exception}, requested_model) do
    {:error,
     failure(
       :transport,
       failure_message(provider, :transport),
       nil,
       requested_model
     )}
  end

  def request_exception(provider, requested_model) do
    {:error,
     failure(
       :transport,
       failure_message(provider, :transport),
       nil,
       requested_model
     )}
  end

  defp malformed_decode_failure(_provider, requested_model) do
    {:error,
     failure(
       :malformed_response,
       "The provider returned an invalid credential-validation response.",
       nil,
       requested_model
     )}
  end

  defp optional_model(nil), do: {:ok, nil}
  defp optional_model(""), do: {:ok, nil}

  defp optional_model(model) when is_binary(model) do
    model = String.trim(model)

    if String.valid?(model) and model != "" and byte_size(model) <= 200 do
      {:ok, model}
    else
      :error
    end
  end

  defp optional_model(_model), do: :error

  defp req_options(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- @allowed_req_options == [] do
      {:ok, options}
    else
      :error
    end
  end

  defp req_options(_options), do: :error

  defp returned_model(%{"id" => model}, _requested_model), do: bounded_model(model)

  defp returned_model(%{"data" => []}, nil), do: {:ok, nil}

  defp returned_model(%{"data" => models}, nil) when is_list(models) do
    case Enum.find_value(models, fn
           %{"id" => model} when is_binary(model) -> model
           _entry -> nil
         end) do
      nil -> {:error, :malformed_response}
      model -> bounded_model(model)
    end
  end

  defp returned_model(_body, _requested_model), do: {:error, :malformed_response}

  defp bounded_model(model)
       when is_binary(model) and byte_size(model) > 0 and byte_size(model) <= 200,
       do: {:ok, model}

  defp bounded_model(_model), do: {:error, :malformed_response}

  defp request_id(response) do
    ["x-request-id", "request-id"]
    |> Enum.find_value(fn header ->
      case Req.Response.get_header(response, header) do
        [value | _rest] -> bounded_request_id(value)
        [] -> nil
      end
    end)
    |> case do
      nil -> body_request_id(response.body)
      value -> value
    end
  end

  defp body_request_id(body) when is_map(body) do
    bounded_request_id(body["request_id"])
  end

  defp body_request_id(_body), do: nil

  defp bounded_request_id(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 200,
       do: value

  defp bounded_request_id(_value), do: nil

  defp failure_category(401, _requested_model), do: :authentication
  defp failure_category(402, _requested_model), do: :authorization
  defp failure_category(403, _requested_model), do: :authorization
  defp failure_category(404, requested_model) when is_binary(requested_model), do: :authorization
  defp failure_category(429, _requested_model), do: :rate_limited
  defp failure_category(_status, _requested_model), do: :provider

  defp failure_message(:openai, :authentication),
    do: "OpenAI rejected the credential. Check the API key."

  defp failure_message(:anthropic, :authentication),
    do: "Anthropic rejected the credential. Check the API key."

  defp failure_message(_provider, :authorization),
    do: "The credential cannot access the requested provider resource or model."

  defp failure_message(_provider, :rate_limited),
    do: "The provider rate-limited the credential validation. Try again later."

  defp failure_message(_provider, :transport),
    do: "Silent Regression could not reach the provider. Try again later."

  defp failure_message(_provider, :provider),
    do: "The provider could not validate the credential. Try again later."

  defp failure(category, message, request_id \\ nil, requested_model \\ nil) do
    %Failure{
      category: category,
      message: message,
      request_id: request_id,
      requested_model: requested_model,
      attempts: 1
    }
  end
end
