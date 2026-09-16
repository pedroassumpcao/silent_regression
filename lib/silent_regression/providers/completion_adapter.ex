defmodule SilentRegression.Providers.CompletionAdapter do
  @moduledoc false

  alias SilentRegression.Contracts.Limits
  alias SilentRegression.Monitors.ModelCatalog
  alias SilentRegression.Providers.{CompletionRequest, CompletionResult, Failure}
  alias SilentRegression.Spike.{Case, Response}

  @category_map %{
    "authentication_error" => :authentication,
    "permission_error" => :authorization,
    "billing_error" => :authorization,
    "rate_limited" => :rate_limited,
    "invalid_request" => :invalid_request,
    "invalid_case" => :invalid_request,
    "configuration_error" => :invalid_request,
    "not_found" => :invalid_request,
    "request_too_large" => :request_too_large,
    "timeout" => :timeout,
    "transport_error" => :transport,
    "provider_unavailable" => :provider_unavailable,
    "conflict" => :provider_unavailable,
    "malformed_response" => :malformed_response,
    "decode_error" => :malformed_response,
    "api_error" => :provider_unavailable,
    "http_error" => :provider_unavailable
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

  def complete_once(provider, spike_adapter, secret, request, options)
      when provider in [:openai, :anthropic] and is_binary(secret) and is_list(options) do
    started_at = System.monotonic_time(:millisecond)

    try do
      with true <- CompletionRequest.valid?(request),
           true <- Keyword.keyword?(options),
           [] <- Keyword.keys(options) -- [:req_options],
           :ok <-
             ModelCatalog.validate_generation_config(
               provider,
               request.requested_model,
               request.generation_config
             ),
           {:ok, case_definition} <- spike_case(request),
           result <-
             spike_adapter.complete(
               case_definition,
               provider_options(provider, secret, request, options)
             ) do
        normalize_result(
          provider,
          request,
          result,
          elapsed(started_at),
          spike_adapter.request_provenance()
        )
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
           elapsed(started_at),
           false
         )}
    end
  end

  def complete_once(_provider, _adapter, _secret, request, _options) do
    {:error,
     failure(
       :invalid_request,
       "The provider completion request is invalid.",
       request,
       0,
       false
     )}
  end

  defp spike_case(request) do
    Case.new(%{
      id: request.case_id,
      version: 1,
      category: "managed_capture",
      description: "Managed capture request",
      system_prompt: request.system_prompt,
      context: context(request.context),
      question: request.user_prompt,
      response_format: Jason.encode!(request.response_format)
    })
  end

  defp context(""), do: "No frozen context was supplied."
  defp context(value), do: value

  defp provider_options(:openai, secret, request, options) do
    generation = request.generation_config

    [
      api_key: secret,
      model: request.requested_model,
      max_output_tokens: generation["max_output_tokens"],
      temperature: generation["temperature"],
      top_p: generation["top_p"],
      reasoning: reasoning(generation["reasoning_effort"]),
      text: openai_text(request.response_format),
      client_request_id: request.client_request_id,
      max_retries: 0,
      retry_delay_ms: 0,
      req_options: Keyword.get(options, :req_options, [])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp provider_options(:anthropic, secret, request, options) do
    generation = request.generation_config

    [
      api_key: secret,
      model: request.requested_model,
      max_output_tokens: generation["max_output_tokens"],
      temperature: generation["temperature"],
      top_p: generation["top_p"],
      max_retries: 0,
      retry_delay_ms: 0,
      req_options: Keyword.get(options, :req_options, [])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp reasoning(nil), do: nil
  defp reasoning(effort), do: %{"effort" => effort}

  defp openai_text(%{"type" => "text"}), do: nil

  defp openai_text(%{"type" => "json_object"}) do
    %{"format" => %{"type" => "json_object"}}
  end

  defp openai_text(%{"type" => "json_schema"} = format) do
    %{
      "format" => %{
        "type" => "json_schema",
        "name" => format["name"],
        "schema" => format["schema"],
        "strict" => Map.get(format, "strict", true)
      }
    }
  end

  defp normalize_result(
         provider,
         request,
         {:ok, %Response{} = response},
         latency_ms,
         provenance
       ) do
    with :ok <- bounded_output(response.output_text),
         {:ok, request_id} <- bounded_request_id(response.request_id) do
      {:ok,
       %CompletionResult{
         provider: provider,
         requested_model: response.requested_model,
         returned_model: response.returned_model,
         output_text: response.output_text,
         request_id: request_id,
         completion_state: completion_state(provider, response.finish_reason),
         input_tokens: response.usage["input_tokens"],
         output_tokens: response.usage["output_tokens"],
         latency_ms: latency_ms,
         finish_reason: response.finish_reason,
         captured_at: DateTime.utc_now(),
         metadata:
           Map.merge(provenance, %{
             "client_request_id" => request.client_request_id,
             "model_mismatch" => response.requested_model != response.returned_model
           })
       }}
    else
      {:error, category} ->
        {:error,
         failure(
           category,
           "The provider returned completion evidence outside the supported limits.",
           request,
           latency_ms,
           false
         )}
    end
  end

  defp normalize_result(_provider, request, {:error, error}, latency_ms, _provenance)
       when is_map(error) do
    category = Map.get(@category_map, error["type"], :provider_unavailable)
    retryable = error["retryable"] == true
    details = Map.get(error, "details", %{})
    request_id = if is_map(details), do: details["request_id"]

    {:error,
     failure(
       category,
       failure_message(category),
       request,
       latency_ms,
       retryable,
       request_id,
       safe_failure_metadata(details)
     )}
  end

  defp normalize_result(_provider, request, _result, latency_ms, _provenance) do
    {:error,
     failure(
       :malformed_response,
       failure_message(:malformed_response),
       request,
       latency_ms,
       false
     )}
  end

  defp completion_state(:openai, finish_reason) when is_binary(finish_reason) do
    if String.starts_with?(finish_reason, "incomplete"), do: :incomplete, else: :complete
  end

  defp completion_state(:anthropic, finish_reason)
       when finish_reason in ["max_tokens", "pause_turn"],
       do: :incomplete

  defp completion_state(:anthropic, _finish_reason), do: :complete

  defp bounded_output(output) when is_binary(output) do
    if byte_size(output) <= Limits.output_bytes(), do: :ok, else: {:error, :malformed_response}
  end

  defp bounded_output(_output), do: {:error, :malformed_response}

  defp bounded_request_id(nil), do: {:ok, nil}

  defp bounded_request_id(value) when is_binary(value) and byte_size(value) <= 512,
    do: {:ok, value}

  defp bounded_request_id(_value), do: {:error, :malformed_response}

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

  defp safe_failure_metadata(details) when is_map(details) do
    details
    |> Map.take(@safe_failure_detail_keys)
    |> Enum.reduce(%{}, fn
      {key, value}, metadata when is_boolean(value) or is_number(value) ->
        Map.put(metadata, key, value)

      {key, value}, metadata when is_binary(value) ->
        if String.valid?(value) and byte_size(value) <= @maximum_failure_detail_length do
          Map.put(metadata, key, value)
        else
          metadata
        end

      {_key, _value}, metadata ->
        metadata
    end)
  end

  defp safe_failure_metadata(_details), do: %{}

  defp requested_model(%CompletionRequest{} = request), do: request.requested_model
  defp requested_model(_request), do: nil

  defp failure_message(:authentication), do: "The provider rejected the credential."
  defp failure_message(:authorization), do: "The credential cannot access the requested model."
  defp failure_message(:rate_limited), do: "The provider rate-limited the request."
  defp failure_message(:invalid_request), do: "The provider rejected the completion request."
  defp failure_message(:request_too_large), do: "The provider rejected the request size."
  defp failure_message(:timeout), do: "The provider request timed out."
  defp failure_message(:transport), do: "The provider request encountered a transport failure."
  defp failure_message(:provider_unavailable), do: "The provider is temporarily unavailable."
  defp failure_message(:malformed_response), do: "The provider returned a malformed response."

  defp elapsed(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)
end
