defmodule SilentRegression.Spike.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API client for the feasibility spike.

  The client requires an explicit model and output-token budget, sends the
  stable Anthropic API version header, and normalizes Messages responses into
  the provider-neutral response contract. Optional sampling parameters are
  omitted unless explicitly supplied.

  Expected API, HTTP, decoding, and transport failures are returned as
  structured provider errors. Retries are performed here, with Req's internal
  retry step disabled, so every HTTP attempt remains observable to the
  experiment call budget.

  Tests inject `Req.Test` through the restricted `:req_options` option. The
  endpoint, method, authentication, API version, body, and retry behavior
  cannot be replaced through that injection point.
  """

  @behaviour SilentRegression.Spike.Provider

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Response

  @endpoint "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @maximum_retries 5
  @maximum_retry_delay_ms 5_000
  @retryable_statuses [408, 409, 429]
  @retryable_transport_reasons [:timeout, :econnrefused, :closed]
  @allowed_options [
    :api_key,
    :max_output_tokens,
    :max_retries,
    :model,
    :req_options,
    :retry_delay_ms,
    :stop_sequences,
    :temperature,
    :top_k,
    :top_p
  ]
  @allowed_req_options [
    :adapter,
    :connect_options,
    :finch,
    :plug,
    :pool_timeout,
    :receive_timeout,
    :request_timeout
  ]

  @impl true
  def id, do: "anthropic"

  @impl true
  def complete(case_definition, options) when is_list(options) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- validate_options(options),
         :ok <- validate_case(case_definition),
         {:ok, config} <- build_config(options),
         payload <- build_payload(case_definition, config),
         {:ok, http_response, attempts} <- request(payload, config) do
      latency_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
      normalize_http_response(http_response, config, attempts, latency_ms)
    end
  end

  def complete(_case_definition, _options) do
    {:error,
     Provider.error(:configuration_error, "Anthropic options must be a keyword list",
       details: %{"field" => "options"}
     )}
  end

  defp validate_options(options) do
    if Keyword.keyword?(options) do
      validate_keyword_options(options)
    else
      {:error,
       Provider.error(:configuration_error, "Anthropic options must be a keyword list",
         details: %{"field" => "options"}
       )}
    end
  end

  defp validate_keyword_options(options) do
    keys = Keyword.keys(options)
    unsupported_options = keys -- @allowed_options

    cond do
      Enum.uniq(keys) != keys ->
        {:error,
         Provider.error(:configuration_error, "Anthropic options contain duplicate keys",
           details: %{"field" => "options"}
         )}

      unsupported_options != [] ->
        {:error,
         Provider.error(:configuration_error, "Anthropic options contain unsupported keys",
           details: %{
             "unsupported_options" => Enum.map(unsupported_options, &Atom.to_string/1)
           }
         )}

      true ->
        :ok
    end
  end

  defp validate_case(%Case{} = case_definition) do
    case Case.validate(case_definition) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Provider.error(:invalid_case, "The case definition is invalid",
           details: %{"reason" => inspect(error)}
         )}
    end
  end

  defp validate_case(_case_definition) do
    {:error,
     Provider.error(:invalid_case, "Expected a spike case definition",
       details: %{"field" => "case_definition"}
     )}
  end

  defp build_config(options) do
    with {:ok, model} <- required_non_empty_option(options, :model),
         {:ok, api_key} <- resolve_api_key(options),
         {:ok, max_output_tokens} <- required_positive_integer(options, :max_output_tokens),
         {:ok, temperature} <- optional_number(options, :temperature, 0.0, 1.0),
         {:ok, top_p} <- optional_number(options, :top_p, 0.0, 1.0),
         {:ok, top_k} <- optional_non_negative_integer(options, :top_k),
         {:ok, stop_sequences} <- optional_string_list(options, :stop_sequences),
         {:ok, max_retries} <- bounded_retries(options),
         {:ok, retry_delay_ms} <- retry_delay(options),
         {:ok, req_options} <- req_options(options) do
      {:ok,
       %{
         model: model,
         api_key: api_key,
         max_output_tokens: max_output_tokens,
         temperature: temperature,
         top_p: top_p,
         top_k: top_k,
         stop_sequences: stop_sequences,
         max_retries: max_retries,
         retry_delay_ms: retry_delay_ms,
         req_options: req_options
       }}
    end
  end

  defp required_non_empty_option(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) ->
        if not String.valid?(value) or String.trim(value) == "" do
          missing_option(name)
        else
          {:ok, value}
        end

      {:ok, _value} ->
        {:error,
         Provider.error(:configuration_error, "Anthropic #{name} must be a non-empty string",
           details: %{"field" => Atom.to_string(name)}
         )}

      :error ->
        missing_option(name)
    end
  end

  defp missing_option(name) do
    {:error,
     Provider.error(:configuration_error, "Anthropic #{name} is required",
       details: %{"field" => Atom.to_string(name)}
     )}
  end

  defp resolve_api_key(options) do
    case Keyword.fetch(options, :api_key) do
      {:ok, api_key} -> validate_api_key(api_key)
      :error -> System.get_env("ANTHROPIC_API_KEY") |> validate_api_key()
    end
  end

  defp validate_api_key(api_key) when is_binary(api_key) do
    if not String.valid?(api_key) or String.trim(api_key) == "" do
      missing_api_key()
    else
      {:ok, api_key}
    end
  end

  defp validate_api_key(_api_key), do: missing_api_key()

  defp missing_api_key do
    {:error,
     Provider.error(:configuration_error, "ANTHROPIC_API_KEY is required",
       details: %{"field" => "api_key"}
     )}
  end

  defp required_positive_integer(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Provider.error(
           :configuration_error,
           "Anthropic #{name} must be a positive integer",
           details: %{"field" => Atom.to_string(name)}
         )}

      :error ->
        missing_option(name)
    end
  end

  defp optional_non_negative_integer(options, name) do
    case Keyword.fetch(options, name) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Provider.error(
           :configuration_error,
           "Anthropic #{name} must be a non-negative integer",
           details: %{"field" => Atom.to_string(name)}
         )}
    end
  end

  defp optional_number(options, name, minimum, maximum) do
    case Keyword.fetch(options, name) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_number(value) and value >= minimum and value <= maximum ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Provider.error(
           :configuration_error,
           "Anthropic #{name} must be between #{minimum} and #{maximum}",
           details: %{"field" => Atom.to_string(name)}
         )}
    end
  end

  defp optional_string_list(options, name) do
    case Keyword.fetch(options, name) do
      :error ->
        {:ok, nil}

      {:ok, values} when is_list(values) ->
        if values != [] and Enum.all?(values, &non_empty_string?/1) do
          {:ok, values}
        else
          invalid_string_list(name)
        end

      {:ok, _value} ->
        invalid_string_list(name)
    end
  end

  defp invalid_string_list(name) do
    {:error,
     Provider.error(
       :configuration_error,
       "Anthropic #{name} must be a non-empty list of non-empty strings",
       details: %{"field" => Atom.to_string(name)}
     )}
  end

  defp non_empty_string?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp non_empty_string?(_value), do: false

  defp bounded_retries(options) do
    max_retries = Keyword.get(options, :max_retries, 2)

    if is_integer(max_retries) and max_retries >= 0 and max_retries <= @maximum_retries do
      {:ok, max_retries}
    else
      {:error,
       Provider.error(
         :configuration_error,
         "Anthropic max_retries must be between 0 and #{@maximum_retries}",
         details: %{"field" => "max_retries", "maximum" => @maximum_retries}
       )}
    end
  end

  defp retry_delay(options) do
    retry_delay_ms = Keyword.get(options, :retry_delay_ms, 250)

    if is_integer(retry_delay_ms) and retry_delay_ms >= 0 and
         retry_delay_ms <= @maximum_retry_delay_ms do
      {:ok, retry_delay_ms}
    else
      {:error,
       Provider.error(
         :configuration_error,
         "Anthropic retry_delay_ms must be between 0 and #{@maximum_retry_delay_ms}",
         details: %{"field" => "retry_delay_ms", "maximum" => @maximum_retry_delay_ms}
       )}
    end
  end

  defp req_options(options) do
    req_options = Keyword.get(options, :req_options, [])

    keys = if Keyword.keyword?(req_options), do: Keyword.keys(req_options), else: []
    unsupported_options = keys -- @allowed_req_options

    cond do
      not Keyword.keyword?(req_options) ->
        {:error,
         Provider.error(:configuration_error, "Anthropic req_options must be a keyword list",
           details: %{"field" => "req_options"}
         )}

      Enum.uniq(keys) != keys ->
        {:error,
         Provider.error(:configuration_error, "Anthropic req_options contain duplicate keys",
           details: %{"field" => "req_options"}
         )}

      unsupported_options != [] ->
        {:error,
         Provider.error(:configuration_error, "Anthropic req_options contain unsafe keys",
           details: %{
             "unsupported_options" => Enum.map(unsupported_options, &Atom.to_string/1)
           }
         )}

      true ->
        {:ok, req_options}
    end
  end

  defp build_payload(case_definition, config) do
    %{
      "model" => config.model,
      "max_tokens" => config.max_output_tokens,
      "system" => case_definition.system_prompt,
      "messages" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => user_input(case_definition)}]
        }
      ]
    }
    |> put_optional("temperature", config.temperature)
    |> put_optional("top_p", config.top_p)
    |> put_optional("top_k", config.top_k)
    |> put_optional("stop_sequences", config.stop_sequences)
  end

  defp user_input(case_definition) do
    """
    Context:
    #{case_definition.context}

    Question:
    #{case_definition.question}

    Response requirements:
    #{case_definition.response_format}
    """
    |> String.trim()
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp request(payload, config), do: request(payload, config, 1)

  defp request(payload, config, attempt) do
    request_options =
      config.req_options
      |> Keyword.put(:method, :post)
      |> Keyword.put(:url, @endpoint)
      |> Keyword.put(:json, payload)
      |> Keyword.put(:headers, request_headers(config.api_key))
      |> Keyword.put(:retry, false)

    result = safe_request(request_options)

    if retryable_result?(result) and attempt <= config.max_retries do
      wait_before_retry(config.retry_delay_ms, attempt)
      request(payload, config, attempt + 1)
    else
      case result do
        {:ok, %Req.Response{} = response} ->
          {:ok, response, attempt}

        {:error, exception} ->
          {:error, request_error(exception, attempt, config.max_retries)}
      end
    end
  end

  defp request_headers(api_key) do
    [
      {"accept", "application/json"},
      {"anthropic-version", @api_version},
      {"x-api-key", api_key}
    ]
  end

  defp safe_request(request_options) do
    Req.request(request_options)
  rescue
    error in Jason.DecodeError -> {:error, error}
  end

  defp retryable_result?({:ok, %Req.Response{status: status}}), do: retryable_status?(status)

  defp retryable_result?({:error, %Req.TransportError{reason: reason}}),
    do: reason in @retryable_transport_reasons

  defp retryable_result?({:error, %Req.HTTPError{protocol: :http2, reason: reason}}),
    do: reason in [:unprocessed, :pool_not_available]

  defp retryable_result?(_result), do: false

  defp retryable_status?(status), do: status in @retryable_statuses or status >= 500

  defp wait_before_retry(0, _attempt), do: :ok

  defp wait_before_retry(base_delay_ms, attempt) do
    multiplier = Integer.pow(2, attempt - 1)
    Process.sleep(min(base_delay_ms * multiplier, @maximum_retry_delay_ms))
  end

  defp normalize_http_response(
         %Req.Response{status: status, body: body} = http_response,
         config,
         attempts,
         latency_ms
       )
       when status >= 200 and status < 300 do
    cond do
      not is_map(body) ->
        malformed_response("body", attempts)

      is_map(body["error"]) ->
        {:error, api_error(body, http_response, attempts)}

      true ->
        normalize_success(body, http_response, config, attempts, latency_ms)
    end
  end

  defp normalize_http_response(%Req.Response{} = response, config, attempts, _latency_ms) do
    {:error, http_error(response, attempts, config.max_retries)}
  end

  defp normalize_success(body, http_response, config, attempts, latency_ms) do
    with {:ok, returned_model} <- required_response_string(body, "model", attempts),
         {:ok, output_text} <- extract_output_text(body, attempts),
         {:ok, usage} <- normalize_usage(body["usage"], attempts),
         {:ok, request_id} <- normalize_request_id(body, http_response, attempts),
         {:ok, finish_reason} <- normalize_finish_reason(body, attempts),
         {:ok, normalized_response} <-
           Response.new(%{
             provider: id(),
             requested_model: config.model,
             returned_model: returned_model,
             output_text: output_text,
             request_id: request_id,
             usage: usage,
             latency_ms: latency_ms,
             finish_reason: finish_reason,
             captured_at: DateTime.utc_now(),
             raw: body,
             attempts: attempts
           }) do
      {:ok, normalized_response}
    else
      {:error, %{"type" => _type} = error} ->
        {:error, error}

      {:error, _validation_error} ->
        malformed_response("normalized_response", attempts)
    end
  end

  defp required_response_string(body, key, attempts) do
    case Map.fetch(body, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          malformed_response(key, attempts)
        else
          {:ok, value}
        end

      _other ->
        malformed_response(key, attempts)
    end
  end

  defp extract_output_text(%{"content" => content}, attempts) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, fragments} when is_binary(text) ->
        {:cont, {:ok, [text | fragments]}}

      %{"type" => "text"}, _accumulator ->
        {:halt, malformed_response("content.text", attempts)}

      _block, accumulator ->
        {:cont, accumulator}
    end)
    |> case do
      {:ok, fragments} -> {:ok, fragments |> Enum.reverse() |> Enum.join("\n")}
      {:error, _error} = failure -> failure
    end
  end

  defp extract_output_text(_body, attempts), do: malformed_response("content", attempts)

  defp normalize_usage(
         %{"input_tokens" => input_tokens, "output_tokens" => output_tokens} = usage,
         attempts
       )
       when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
              output_tokens >= 0 do
    with {:ok, cache_creation_tokens} <-
           optional_usage_tokens(usage, "cache_creation_input_tokens", attempts),
         {:ok, cache_read_tokens} <-
           optional_usage_tokens(usage, "cache_read_input_tokens", attempts) do
      {:ok,
       %{
         "input_tokens" => input_tokens + cache_creation_tokens + cache_read_tokens,
         "output_tokens" => output_tokens
       }}
    end
  end

  defp normalize_usage(_usage, attempts), do: malformed_response("usage", attempts)

  defp optional_usage_tokens(usage, key, attempts) do
    case Map.fetch(usage, key) do
      :error -> {:ok, 0}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> malformed_response("usage.#{key}", attempts)
    end
  end

  defp normalize_request_id(body, http_response, attempts) do
    request_id = response_request_id(http_response) || body["request_id"] || body["id"]

    cond do
      is_nil(request_id) -> {:ok, nil}
      is_binary(request_id) and String.trim(request_id) != "" -> {:ok, request_id}
      true -> malformed_response("id", attempts)
    end
  end

  defp response_request_id(http_response) do
    case Req.Response.get_header(http_response, "request-id") do
      [request_id | _rest] -> request_id
      [] -> nil
    end
  end

  defp normalize_finish_reason(body, attempts) do
    case body["stop_reason"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> malformed_response("stop_reason", attempts)
    end
  end

  defp malformed_response(field, attempts) do
    {:error,
     Provider.error(:malformed_response, "Anthropic returned a malformed response",
       details: %{"attempts" => attempts, "field" => field}
     )}
  end

  defp api_error(body, http_response, attempts) do
    error_body = body["error"]

    details =
      %{"attempts" => attempts}
      |> put_error_detail("request_id", body["request_id"] || response_request_id(http_response))
      |> put_error_detail("provider_type", error_body["type"])

    Provider.error(
      :api_error,
      provider_message(error_body, "Anthropic reported a response error"),
      details: details
    )
  end

  defp http_error(%Req.Response{status: status, body: body} = response, attempts, max_retries) do
    retryable? = retryable_status?(status)
    error_body = if is_map(body) and is_map(body["error"]), do: body["error"], else: %{}

    request_id =
      if is_map(body), do: body["request_id"] || response_request_id(response), else: nil

    details =
      %{
        "status" => status,
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => retryable? and attempts > max_retries
      }
      |> put_error_detail("request_id", request_id)
      |> put_error_detail("provider_type", error_body["type"])

    {type, fallback_message} = http_error_identity(status)

    Provider.error(type, provider_message(error_body, fallback_message),
      retryable?: retryable?,
      details: details
    )
  end

  defp http_error_identity(400), do: {:invalid_request, "Anthropic rejected the request"}
  defp http_error_identity(401), do: {:authentication_error, "Anthropic authentication failed"}
  defp http_error_identity(402), do: {:billing_error, "Anthropic billing authorization failed"}
  defp http_error_identity(403), do: {:permission_error, "Anthropic denied the request"}
  defp http_error_identity(404), do: {:not_found, "Anthropic could not find the resource"}
  defp http_error_identity(408), do: {:timeout, "Anthropic timed out processing the request"}
  defp http_error_identity(409), do: {:conflict, "Anthropic reported a request conflict"}
  defp http_error_identity(413), do: {:request_too_large, "Anthropic rejected a large request"}
  defp http_error_identity(429), do: {:rate_limited, "Anthropic rate-limited the request"}
  defp http_error_identity(504), do: {:timeout, "Anthropic timed out processing the request"}

  defp http_error_identity(status) when status >= 500,
    do: {:provider_unavailable, "Anthropic is temporarily unavailable"}

  defp http_error_identity(_status), do: {:http_error, "Anthropic returned an HTTP error"}

  defp provider_message(error_body, fallback) do
    case error_body["message"] do
      message when is_binary(message) ->
        if String.trim(message) == "", do: fallback, else: message

      _message ->
        fallback
    end
  end

  defp put_error_detail(details, _key, nil), do: details

  defp put_error_detail(details, key, value)
       when is_binary(value) or is_boolean(value) or is_number(value) do
    Map.put(details, key, value)
  end

  defp put_error_detail(details, _key, _value), do: details

  defp request_error(%Jason.DecodeError{}, attempts, max_retries) do
    Provider.error(:decode_error, "Anthropic returned malformed JSON",
      details: %{
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => false
      }
    )
  end

  defp request_error(%Req.TransportError{reason: reason}, attempts, max_retries) do
    retryable? = reason in @retryable_transport_reasons
    type = if reason == :timeout, do: :timeout, else: :transport_error

    Provider.error(type, transport_message(reason),
      retryable?: retryable?,
      details: %{
        "reason" => inspect(reason),
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => retryable? and attempts > max_retries
      }
    )
  end

  defp request_error(%Req.HTTPError{protocol: protocol, reason: reason}, attempts, max_retries) do
    retryable? = protocol == :http2 and reason in [:unprocessed, :pool_not_available]

    Provider.error(:transport_error, "Anthropic HTTP transport failed",
      retryable?: retryable?,
      details: %{
        "protocol" => inspect(protocol),
        "reason" => inspect(reason),
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => retryable? and attempts > max_retries
      }
    )
  end

  defp request_error(exception, attempts, max_retries) do
    Provider.error(:transport_error, "Anthropic request failed",
      details: %{
        "exception" => exception_name(exception),
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => false
      }
    )
  end

  defp transport_message(:timeout), do: "Anthropic request timed out"
  defp transport_message(_reason), do: "Anthropic transport connection failed"

  defp exception_name(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp exception_name(_exception), do: "unknown"
end
