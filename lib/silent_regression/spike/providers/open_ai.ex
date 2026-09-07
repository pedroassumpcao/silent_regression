defmodule SilentRegression.Spike.Providers.OpenAI do
  @moduledoc """
  OpenAI Responses API client for the feasibility spike.

  Requests are stateless (`store: false`) and use an explicit model. Expected
  API, HTTP, decoding, and transport failures are returned as structured
  provider errors. Retries are performed here, with Req's internal retry step
  disabled, so every HTTP attempt is observable to the experiment call budget.

  Tests inject `Req.Test` through the restricted `:req_options` option. The
  endpoint, method, authorization, body, and retry behavior cannot be replaced
  through that injection point.
  """

  @behaviour SilentRegression.Spike.Provider

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.Validation

  @endpoint "https://api.openai.com/v1/responses"
  @maximum_retries 5
  @maximum_retry_delay_ms 5_000
  @retryable_statuses [408, 429, 500, 502, 503, 504]
  @retryable_transport_reasons [:timeout, :econnrefused, :closed]
  @allowed_options [
    :api_key,
    :max_output_tokens,
    :max_retries,
    :model,
    :reasoning,
    :req_options,
    :retry_delay_ms,
    :temperature,
    :text,
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
  def id, do: "openai"

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
     Provider.error(:configuration_error, "OpenAI options must be a keyword list",
       details: %{"field" => "options"}
     )}
  end

  defp validate_options(options) do
    if Keyword.keyword?(options) do
      validate_keyword_options(options)
    else
      {:error,
       Provider.error(:configuration_error, "OpenAI options must be a keyword list",
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
         Provider.error(:configuration_error, "OpenAI options contain duplicate keys",
           details: %{"field" => "options"}
         )}

      unsupported_options != [] ->
        {:error,
         Provider.error(:configuration_error, "OpenAI options contain unsupported keys",
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
         {:ok, max_output_tokens} <- optional_positive_integer(options, :max_output_tokens),
         {:ok, temperature} <- optional_number(options, :temperature, 0.0, 2.0),
         {:ok, top_p} <- optional_number(options, :top_p, 0.0, 1.0),
         {:ok, reasoning} <- optional_json_object(options, :reasoning),
         {:ok, text} <- optional_json_object(options, :text),
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
         reasoning: reasoning,
         text: text,
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
         Provider.error(:configuration_error, "OpenAI #{name} must be a non-empty string",
           details: %{"field" => Atom.to_string(name)}
         )}

      :error ->
        missing_option(name)
    end
  end

  defp missing_option(name) do
    {:error,
     Provider.error(:configuration_error, "OpenAI #{name} is required",
       details: %{"field" => Atom.to_string(name)}
     )}
  end

  defp resolve_api_key(options) do
    case Keyword.fetch(options, :api_key) do
      {:ok, api_key} -> validate_api_key(api_key)
      :error -> System.get_env("OPENAI_API_KEY") |> validate_api_key()
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
     Provider.error(:configuration_error, "OPENAI_API_KEY is required",
       details: %{"field" => "api_key"}
     )}
  end

  defp optional_positive_integer(options, name) do
    case Keyword.fetch(options, name) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error,
         Provider.error(:configuration_error, "OpenAI #{name} must be a positive integer",
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
           "OpenAI #{name} must be between #{minimum} and #{maximum}",
           details: %{"field" => Atom.to_string(name)}
         )}
    end
  end

  defp optional_json_object(options, name) do
    case Keyword.fetch(options, name) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case Validation.json_object(value, name, __MODULE__) do
          :ok ->
            {:ok, value}

          {:error, _error} ->
            {:error,
             Provider.error(:configuration_error, "OpenAI #{name} must be a JSON object",
               details: %{"field" => Atom.to_string(name)}
             )}
        end
    end
  end

  defp bounded_retries(options) do
    max_retries = Keyword.get(options, :max_retries, 2)

    if is_integer(max_retries) and max_retries >= 0 and max_retries <= @maximum_retries do
      {:ok, max_retries}
    else
      {:error,
       Provider.error(
         :configuration_error,
         "OpenAI max_retries must be between 0 and #{@maximum_retries}",
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
         "OpenAI retry_delay_ms must be between 0 and #{@maximum_retry_delay_ms}",
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
         Provider.error(:configuration_error, "OpenAI req_options must be a keyword list",
           details: %{"field" => "req_options"}
         )}

      Enum.uniq(keys) != keys ->
        {:error,
         Provider.error(:configuration_error, "OpenAI req_options contain duplicate keys",
           details: %{"field" => "req_options"}
         )}

      unsupported_options != [] ->
        {:error,
         Provider.error(:configuration_error, "OpenAI req_options contain unsafe keys",
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
      "store" => false,
      "input" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => user_input(case_definition)
            }
          ]
        }
      ]
    }
    |> put_optional("instructions", case_definition.system_prompt)
    |> put_optional("max_output_tokens", config.max_output_tokens)
    |> put_optional("temperature", config.temperature)
    |> put_optional("top_p", config.top_p)
    |> put_optional("reasoning", config.reasoning)
    |> put_optional("text", config.text)
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
      |> Keyword.put(:auth, {:bearer, config.api_key})
      |> Keyword.put(:headers, [{"accept", "application/json"}])
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

  defp safe_request(request_options) do
    Req.request(request_options)
  rescue
    error in Jason.DecodeError -> {:error, error}
  end

  defp retryable_result?({:ok, %Req.Response{status: status}}),
    do: status in @retryable_statuses

  defp retryable_result?({:error, %Req.TransportError{reason: reason}}),
    do: reason in @retryable_transport_reasons

  defp retryable_result?({:error, %Req.HTTPError{protocol: :http2, reason: reason}}),
    do: reason in [:unprocessed, :pool_not_available]

  defp retryable_result?(_result), do: false

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
        {:error, api_error(body["error"], attempts)}

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
         {:ok, normalized_response} <-
           Response.new(%{
             provider: id(),
             requested_model: config.model,
             returned_model: returned_model,
             output_text: output_text,
             request_id: request_id,
             usage: usage,
             latency_ms: latency_ms,
             finish_reason: finish_reason(body),
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

  defp extract_output_text(body, attempts) do
    fragments =
      case body["output"] do
        output when is_list(output) -> Enum.flat_map(output, &output_item_text/1)
        _output -> []
      end

    cond do
      fragments != [] ->
        {:ok, Enum.join(fragments, "\n")}

      is_binary(body["output_text"]) ->
        {:ok, body["output_text"]}

      true ->
        malformed_response("output", attempts)
    end
  end

  defp output_item_text(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &content_block_text/1)
  end

  defp output_item_text(%{"type" => "output_text", "text" => text}) when is_binary(text),
    do: [text]

  defp output_item_text(%{"type" => "refusal", "refusal" => refusal})
       when is_binary(refusal),
       do: [refusal]

  defp output_item_text(_item), do: []

  defp content_block_text(%{"type" => "output_text", "text" => text}) when is_binary(text),
    do: [text]

  defp content_block_text(%{"type" => "refusal", "refusal" => refusal})
       when is_binary(refusal),
       do: [refusal]

  defp content_block_text(_content), do: []

  defp normalize_usage(
         %{"input_tokens" => input_tokens, "output_tokens" => output_tokens},
         _attempts
       )
       when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
              output_tokens >= 0 do
    {:ok, %{"input_tokens" => input_tokens, "output_tokens" => output_tokens}}
  end

  defp normalize_usage(_usage, attempts), do: malformed_response("usage", attempts)

  defp normalize_request_id(body, http_response, attempts) do
    request_id = body["id"] || response_request_id(http_response)

    cond do
      is_nil(request_id) -> {:ok, nil}
      is_binary(request_id) and String.trim(request_id) != "" -> {:ok, request_id}
      true -> malformed_response("id", attempts)
    end
  end

  defp response_request_id(http_response) do
    case Req.Response.get_header(http_response, "x-request-id") do
      [request_id | _rest] -> request_id
      [] -> nil
    end
  end

  defp finish_reason(%{"status" => "incomplete", "incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: "incomplete:#{reason}"

  defp finish_reason(%{"status" => status}) when is_binary(status), do: status
  defp finish_reason(_body), do: nil

  defp malformed_response(field, attempts) do
    {:error,
     Provider.error(:malformed_response, "OpenAI returned a malformed response",
       details: %{"attempts" => attempts, "field" => field}
     )}
  end

  defp api_error(error_body, attempts) do
    details =
      %{"attempts" => attempts}
      |> put_error_detail("provider_type", error_body["type"])
      |> put_error_detail("provider_code", error_body["code"])
      |> put_error_detail("provider_param", error_body["param"])

    Provider.error(:api_error, provider_message(error_body, "OpenAI reported a response error"),
      details: details
    )
  end

  defp http_error(%Req.Response{status: status, body: body} = response, attempts, max_retries) do
    retryable? = status in @retryable_statuses
    error_body = if is_map(body) and is_map(body["error"]), do: body["error"], else: %{}

    details =
      %{
        "status" => status,
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => retryable? and attempts > max_retries
      }
      |> put_error_detail("request_id", response_request_id(response))
      |> put_error_detail("provider_type", error_body["type"])
      |> put_error_detail("provider_code", error_body["code"])
      |> put_error_detail("provider_param", error_body["param"])

    {type, fallback_message} = http_error_identity(status)

    Provider.error(type, provider_message(error_body, fallback_message),
      retryable?: retryable?,
      details: details
    )
  end

  defp http_error_identity(400), do: {:invalid_request, "OpenAI rejected the request"}
  defp http_error_identity(401), do: {:authentication_error, "OpenAI authentication failed"}
  defp http_error_identity(403), do: {:permission_error, "OpenAI denied the request"}
  defp http_error_identity(404), do: {:not_found, "OpenAI could not find the requested resource"}
  defp http_error_identity(408), do: {:timeout, "OpenAI timed out processing the request"}
  defp http_error_identity(429), do: {:rate_limited, "OpenAI rate-limited the request"}

  defp http_error_identity(status) when status >= 500,
    do: {:provider_unavailable, "OpenAI is temporarily unavailable"}

  defp http_error_identity(_status), do: {:http_error, "OpenAI returned an HTTP error"}

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
    Provider.error(:decode_error, "OpenAI returned malformed JSON",
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

    Provider.error(:transport_error, "OpenAI HTTP transport failed",
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
    Provider.error(:transport_error, "OpenAI request failed",
      details: %{
        "exception" => exception_name(exception),
        "attempts" => attempts,
        "max_retries" => max_retries,
        "retries_exhausted" => false
      }
    )
  end

  defp transport_message(:timeout), do: "OpenAI request timed out"
  defp transport_message(_reason), do: "OpenAI transport connection failed"

  defp exception_name(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp exception_name(_exception), do: "unknown"
end
