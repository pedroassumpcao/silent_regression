defmodule SilentRegression.Providers.CompletionAdapter do
  @moduledoc false

  alias SilentRegression.Contracts.Limits
  alias SilentRegression.Providers.{CompletionRequest, CompletionResult, Failure}

  @endpoints %{
    openai: {"https://api.openai.com/v1/responses", "v1"},
    anthropic: {"https://api.anthropic.com/v1/messages", "2023-06-01"}
  }
  @allowed_req_options [
    :adapter,
    :connect_options,
    :finch,
    :plug,
    :pool_timeout,
    :receive_timeout,
    :request_timeout
  ]
  @retryable_statuses %{
    openai: [408, 429, 500, 502, 503, 504],
    anthropic: [408, 409, 429, 500, 502, 503, 504]
  }
  @safe_failure_detail_keys ~w(
    attempts
    max_retries
    provider_code
    provider_param
    provider_type
    retries_exhausted
    status
  )
  @maximum_failure_detail_length 200

  def complete_once(provider, secret, request, options)
      when provider in [:openai, :anthropic] and is_binary(secret) and is_list(options) do
    started_at = System.monotonic_time(:millisecond)

    with true <- CompletionRequest.valid?(request),
         :ok <- validate_request_artifact(provider, request),
         {:ok, req_options} <- req_options(options),
         result <- request(provider, secret, request, req_options) do
      normalize_result(provider, request, result, elapsed(started_at))
    else
      _reason ->
        {:error,
         failure(
           :invalid_request,
           "The provider completion request is invalid.",
           request,
           elapsed(started_at),
           false
         )}
    end
  rescue
    _error ->
      {:error,
       failure(
         :provider_unavailable,
         "The provider adapter could not complete the request.",
         request,
         0,
         false
       )}
  end

  def complete_once(_provider, _secret, request, _options) do
    {:error,
     failure(
       :invalid_request,
       "The provider completion request is invalid.",
       request,
       0,
       false
     )}
  end

  defp validate_request_artifact(provider, request) do
    {endpoint, api_version} = Map.fetch!(@endpoints, provider)
    artifact = request.request_artifact

    if artifact == %{
         "artifact_schema" => "provider-request-artifact-v1",
         "request_mode" => Atom.to_string(request.request_mode),
         "request_schema_version" => request.request_schema_version,
         "provider" => Atom.to_string(provider),
         "http_method" => "POST",
         "api_endpoint" => endpoint,
         "api_version" => api_version,
         "body" => artifact["body"]
       } and is_map(artifact["body"]) do
      :ok
    else
      {:error, :invalid_request_artifact}
    end
  end

  defp req_options(options) do
    with true <- Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- [:req_options],
         req_options when is_list(req_options) <- Keyword.get(options, :req_options, []),
         true <- Keyword.keyword?(req_options),
         keys <- Keyword.keys(req_options),
         true <- Enum.uniq(keys) == keys,
         [] <- keys -- @allowed_req_options do
      {:ok, req_options}
    else
      _reason -> {:error, :invalid_options}
    end
  end

  defp request(provider, secret, request, req_options) do
    {endpoint, _api_version} = Map.fetch!(@endpoints, provider)

    request_options =
      req_options
      |> Keyword.put(:method, :post)
      |> Keyword.put(:url, endpoint)
      |> Keyword.put(:json, request.request_artifact["body"])
      |> Keyword.put(:headers, request_headers(provider, secret, request.client_request_id))
      |> Keyword.put(:retry, false)

    safe_request(request_options)
  end

  defp request_headers(:openai, secret, client_request_id) do
    [
      {"accept", "application/json"},
      {"authorization", "Bearer #{secret}"},
      {"x-client-request-id", client_request_id}
    ]
  end

  defp request_headers(:anthropic, secret, _client_request_id) do
    [
      {"accept", "application/json"},
      {"anthropic-version", "2023-06-01"},
      {"x-api-key", secret}
    ]
  end

  defp safe_request(request_options) do
    Req.request(request_options)
  rescue
    error -> {:error, error}
  end

  defp normalize_result(
         provider,
         request,
         {:ok, %Req.Response{status: status, body: body} = response},
         latency_ms
       )
       when status >= 200 and status < 300 do
    if is_map(body) and not is_map(body["error"]) do
      normalize_success(provider, request, body, response, latency_ms)
    else
      malformed_response(request, latency_ms)
    end
  end

  defp normalize_result(
         provider,
         request,
         {:ok, %Req.Response{} = response},
         latency_ms
       ) do
    status = response.status
    error_body = if is_map(response.body), do: response.body["error"] || %{}, else: %{}
    {category, message} = http_error_identity(provider, status)
    retryable = status in Map.fetch!(@retryable_statuses, provider)

    details =
      %{
        "status" => status,
        "attempts" => 1,
        "max_retries" => 0,
        "retries_exhausted" => retryable
      }
      |> put_detail("provider_type", map_value(error_body, "type"))
      |> put_detail("provider_code", map_value(error_body, "code"))
      |> put_detail("provider_param", map_value(error_body, "param"))

    {:error,
     failure(
       category,
       message,
       request,
       latency_ms,
       retryable,
       response_request_id(provider, response),
       safe_failure_metadata(details)
     )}
  end

  defp normalize_result(_provider, request, {:error, reason}, latency_ms) do
    {category, retryable} = transport_identity(reason)

    {:error,
     failure(
       category,
       failure_message(category),
       request,
       latency_ms,
       retryable,
       nil,
       %{"attempts" => 1, "max_retries" => 0, "retries_exhausted" => retryable}
     )}
  end

  defp normalize_result(_provider, request, _result, latency_ms),
    do: malformed_response(request, latency_ms)

  defp normalize_success(:openai, request, body, response, latency_ms) do
    with {:ok, returned_model} <- required_string(body, "model"),
         {:ok, output_text} <- openai_output_text(body),
         {:ok, {input_tokens, output_tokens}} <- usage(body["usage"], :openai),
         {:ok, request_id} <-
           bounded_request_id(body["id"] || response_request_id(:openai, response)),
         :ok <- bounded_output(output_text) do
      finish_reason = openai_finish_reason(body)

      completion_result(
        :openai,
        request,
        returned_model,
        output_text,
        request_id,
        completion_state(:openai, finish_reason),
        input_tokens,
        output_tokens,
        latency_ms,
        finish_reason
      )
    else
      _reason -> malformed_response(request, latency_ms)
    end
  end

  defp normalize_success(:anthropic, request, body, response, latency_ms) do
    with {:ok, returned_model} <- required_string(body, "model"),
         {:ok, output_text} <- anthropic_output_text(body),
         {:ok, {input_tokens, output_tokens}} <- usage(body["usage"], :anthropic),
         {:ok, request_id} <-
           bounded_request_id(
             response_request_id(:anthropic, response) || body["request_id"] || body["id"]
           ),
         {:ok, finish_reason} <- required_string(body, "stop_reason"),
         :ok <- bounded_output(output_text) do
      completion_result(
        :anthropic,
        request,
        returned_model,
        output_text,
        request_id,
        completion_state(:anthropic, finish_reason),
        input_tokens,
        output_tokens,
        latency_ms,
        finish_reason
      )
    else
      _reason -> malformed_response(request, latency_ms)
    end
  end

  defp completion_result(
         provider,
         request,
         returned_model,
         output_text,
         request_id,
         completion_state,
         input_tokens,
         output_tokens,
         latency_ms,
         finish_reason
       ) do
    {endpoint, api_version} = Map.fetch!(@endpoints, provider)

    {:ok,
     %CompletionResult{
       provider: provider,
       requested_model: request.requested_model,
       returned_model: returned_model,
       output_text: output_text,
       request_id: request_id,
       completion_state: completion_state,
       input_tokens: input_tokens,
       output_tokens: output_tokens,
       latency_ms: latency_ms,
       finish_reason: finish_reason,
       captured_at: DateTime.utc_now(),
       metadata: %{
         "api_endpoint" => endpoint,
         "api_version" => api_version,
         "client_request_id" => request.client_request_id,
         "http_method" => "POST",
         "model_mismatch" => request.requested_model != returned_model
       }
     }}
  end

  defp openai_output_text(body) do
    fragments =
      case body["output"] do
        output when is_list(output) -> Enum.flat_map(output, &openai_output_item_text/1)
        _output -> []
      end

    cond do
      fragments != [] -> {:ok, Enum.join(fragments, "\n")}
      is_binary(body["output_text"]) -> {:ok, body["output_text"]}
      true -> {:error, :missing_output}
    end
  end

  defp openai_output_item_text(%{"content" => content}) when is_list(content),
    do: Enum.flat_map(content, &openai_output_item_text/1)

  defp openai_output_item_text(%{"type" => "output_text", "text" => text})
       when is_binary(text),
       do: [text]

  defp openai_output_item_text(%{"type" => "refusal", "refusal" => refusal})
       when is_binary(refusal),
       do: [refusal]

  defp openai_output_item_text(_item), do: []

  defp anthropic_output_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, fragments} when is_binary(text) ->
        {:cont, {:ok, [text | fragments]}}

      %{"type" => "text"}, _accumulator ->
        {:halt, {:error, :invalid_text_block}}

      _block, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:ok, fragments} -> {:ok, fragments |> Enum.reverse() |> Enum.join("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp anthropic_output_text(_body), do: {:error, :missing_content}

  defp usage(%{"input_tokens" => input, "output_tokens" => output}, :openai)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: {:ok, {input, output}}

  defp usage(%{"input_tokens" => input, "output_tokens" => output} = usage, :anthropic)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    with {:ok, creation} <- optional_non_negative(usage, "cache_creation_input_tokens"),
         {:ok, read} <- optional_non_negative(usage, "cache_read_input_tokens") do
      {:ok, {input + creation + read, output}}
    end
  end

  defp usage(_usage, _provider), do: {:error, :invalid_usage}

  defp optional_non_negative(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, 0}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_usage}
    end
  end

  defp required_string(map, key) do
    case map[key] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :blank}, else: {:ok, value}

      _value ->
        {:error, :invalid_string}
    end
  end

  defp bounded_output(output) when is_binary(output) do
    if byte_size(output) <= Limits.output_bytes(), do: :ok, else: {:error, :output_too_large}
  end

  defp bounded_output(_output), do: {:error, :invalid_output}

  defp bounded_request_id(nil), do: {:ok, nil}

  defp bounded_request_id(value) when is_binary(value) and byte_size(value) <= 512,
    do: {:ok, value}

  defp bounded_request_id(_value), do: {:error, :invalid_request_id}

  defp response_request_id(:openai, response), do: first_header(response, "x-request-id")
  defp response_request_id(:anthropic, response), do: first_header(response, "request-id")

  defp first_header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp openai_finish_reason(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => reason}
       })
       when is_binary(reason),
       do: "incomplete:#{reason}"

  defp openai_finish_reason(%{"status" => status}) when is_binary(status), do: status
  defp openai_finish_reason(_body), do: nil

  defp completion_state(:openai, finish_reason) when is_binary(finish_reason) do
    if String.starts_with?(finish_reason, "incomplete"), do: :incomplete, else: :complete
  end

  defp completion_state(:openai, _finish_reason), do: :complete

  defp completion_state(:anthropic, finish_reason)
       when finish_reason in ["max_tokens", "pause_turn"],
       do: :incomplete

  defp completion_state(:anthropic, _finish_reason), do: :complete

  defp transport_identity(%Req.TransportError{reason: :timeout}), do: {:timeout, true}

  defp transport_identity(%Req.TransportError{reason: reason})
       when reason in [:econnrefused, :closed],
       do: {:transport, true}

  defp transport_identity(%Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available],
       do: {:transport, true}

  defp transport_identity(%Jason.DecodeError{}), do: {:malformed_response, false}
  defp transport_identity(_reason), do: {:transport, false}

  defp http_error_identity(provider, 400) when provider in [:openai, :anthropic],
    do: {:invalid_request, "The provider rejected the completion request."}

  defp http_error_identity(_provider, 401),
    do: {:authentication, "The provider rejected the credential."}

  defp http_error_identity(_provider, status) when status in [402, 403],
    do: {:authorization, "The credential cannot access the requested model."}

  defp http_error_identity(_provider, 408),
    do: {:timeout, "The provider request timed out."}

  defp http_error_identity(:anthropic, 413),
    do: {:request_too_large, "The provider rejected the request size."}

  defp http_error_identity(_provider, 429),
    do: {:rate_limited, "The provider rate-limited the request."}

  defp http_error_identity(_provider, status) when status >= 500,
    do: {:provider_unavailable, "The provider is temporarily unavailable."}

  defp http_error_identity(_provider, _status),
    do: {:provider_unavailable, "The provider is temporarily unavailable."}

  defp malformed_response(request, latency_ms) do
    {:error,
     failure(
       :malformed_response,
       failure_message(:malformed_response),
       request,
       latency_ms,
       false
     )}
  end

  defp failure(category, message, request, latency_ms, retryable) do
    failure(category, message, request, latency_ms, retryable, nil, %{})
  end

  defp failure(category, message, request, latency_ms, retryable, request_id, metadata) do
    %Failure{
      category: category,
      message: message,
      request_id: request_id,
      requested_model: requested_model(request),
      attempts: 1,
      retryable: retryable,
      latency_ms: latency_ms,
      metadata: metadata
    }
  end

  defp safe_failure_metadata(details) do
    details
    |> Map.take(@safe_failure_detail_keys)
    |> Enum.reduce(%{}, fn
      {key, value}, metadata when is_boolean(value) or is_number(value) ->
        Map.put(metadata, key, value)

      {key, value}, metadata when is_binary(value) ->
        if String.valid?(value) and byte_size(value) <= @maximum_failure_detail_length,
          do: Map.put(metadata, key, value),
          else: metadata

      {_key, _value}, metadata ->
        metadata
    end)
  end

  defp put_detail(map, _key, nil), do: map
  defp put_detail(map, key, value), do: Map.put(map, key, value)
  defp map_value(value, key) when is_map(value), do: value[key]
  defp map_value(_value, _key), do: nil

  defp requested_model(%CompletionRequest{} = request), do: request.requested_model
  defp requested_model(_request), do: nil

  defp failure_message(:timeout), do: "The provider request timed out."
  defp failure_message(:transport), do: "The provider request encountered a transport failure."
  defp failure_message(:malformed_response), do: "The provider returned a malformed response."

  defp elapsed(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)
end
