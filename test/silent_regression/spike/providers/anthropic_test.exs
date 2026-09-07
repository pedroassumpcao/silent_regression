defmodule SilentRegression.Spike.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Providers.Anthropic
  alias SilentRegression.Spike.Response
  alias SilentRegression.SpikeFixtures

  @stub __MODULE__

  setup {Req.Test, :verify_on_exit!}

  test "identifies the provider" do
    assert Anthropic.id() == "anthropic"
  end

  test "posts a versioned Messages API request and normalizes every response field" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-api-key"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

      body = decoded_request_body(conn)
      assert body["model"] == "requested-model"
      assert body["max_tokens"] == 256
      assert body["system"] == "Use only the supplied context."
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "top_p")
      refute Map.has_key?(body, "top_k")
      refute Map.has_key?(body, "stop_sequences")

      [%{"role" => "user", "content" => [%{"type" => "text", "text" => input}]}] =
        body["messages"]

      assert input =~ "Context:\nFrozen source material"
      assert input =~ "Question:\nWhat happened?"
      assert input =~ "Response requirements:\nAnswer concisely."

      conn
      |> Plug.Conn.put_resp_header("request-id", "req_123")
      |> Req.Test.json(success_body())
    end)

    before_call = DateTime.utc_now()

    assert {:ok, %Response{} = response} =
             Anthropic.complete(case_definition(),
               model: "requested-model",
               api_key: "test-api-key",
               max_output_tokens: 256,
               req_options: req_options()
             )

    assert response.provider == "anthropic"
    assert response.requested_model == "requested-model"
    assert response.returned_model == "requested-model"
    assert response.output_text == "Grounded answer."
    assert response.request_id == "req_123"
    assert response.usage == %{"input_tokens" => 101, "output_tokens" => 12}
    assert response.latency_ms >= 0
    assert response.finish_reason == "end_turn"
    assert DateTime.compare(response.captured_at, before_call) in [:eq, :gt]
    assert response.raw == success_body()
    assert response.attempts == 1
  end

  test "joins text blocks in order while ignoring non-text blocks" do
    content = [
      %{"type" => "thinking", "thinking" => "not output"},
      %{"type" => "text", "text" => "First paragraph."},
      %{"type" => "tool_use", "id" => "tool_1", "name" => "ignored", "input" => %{}},
      %{"type" => "redacted_thinking", "data" => "opaque"},
      %{"type" => "text", "text" => "Final paragraph."}
    ]

    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, success_body(%{"content" => content}))
    end)

    assert {:ok, response} = complete()
    assert response.output_text == "First paragraph.\nFinal paragraph."
  end

  test "normalizes a response containing only non-text blocks to empty output" do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(
        conn,
        success_body(%{
          "content" => [%{"type" => "tool_use", "id" => "tool_1", "input" => %{}}],
          "stop_reason" => "tool_use"
        })
      )
    end)

    assert {:ok, response} = complete()
    assert response.output_text == ""
    assert response.finish_reason == "tool_use"
  end

  test "records requested and returned model IDs when they differ" do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, success_body(%{"model" => "effective-model-snapshot"}))
    end)

    assert {:ok, response} = complete(model: "requested-model-alias")
    assert response.requested_model == "requested-model-alias"
    assert response.returned_model == "effective-model-snapshot"
  end

  test "includes sampling parameters only when explicitly supplied" do
    Req.Test.expect(@stub, fn conn ->
      body = decoded_request_body(conn)
      assert body["temperature"] == 0.4
      assert body["top_p"] == 0.9
      assert body["top_k"] == 20
      assert body["stop_sequences"] == ["END"]

      Req.Test.json(conn, success_body())
    end)

    assert {:ok, _response} =
             complete(
               temperature: 0.4,
               top_p: 0.9,
               top_k: 20,
               stop_sequences: ["END"]
             )
  end

  test "missing required configuration fails before any HTTP request" do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, :unexpected_anthropic_request)
      Req.Test.json(conn, success_body())
    end)

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "model"}
            }} =
             Anthropic.complete(case_definition(),
               api_key: "test-api-key",
               max_output_tokens: 256,
               req_options: req_options()
             )

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "api_key"}
            }} =
             Anthropic.complete(case_definition(),
               model: "requested-model",
               api_key: "",
               max_output_tokens: 256,
               req_options: req_options()
             )

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "max_output_tokens"}
            }} =
             Anthropic.complete(case_definition(),
               model: "requested-model",
               api_key: "test-api-key",
               req_options: req_options()
             )

    refute_received :unexpected_anthropic_request
  end

  test "a 400 response preserves the Anthropic error shape and request ID" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 400, "invalid_request_error", "Bad input", "req_bad_input")
    end)

    assert {:error, error} = complete(max_retries: 2)

    assert error["type"] == "invalid_request"
    assert error["message"] == "Bad input"
    refute error["retryable"]
    assert error["details"]["status"] == 400
    assert error["details"]["attempts"] == 1
    assert error["details"]["provider_type"] == "invalid_request_error"
    assert error["details"]["request_id"] == "req_bad_input"
  end

  test "a 401 response is structured without exposing the API key" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 401, "authentication_error", "Invalid key")
    end)

    assert {:error, error} = complete()

    assert error["type"] == "authentication_error"
    refute error["retryable"]
    assert error["details"]["attempts"] == 1
    refute inspect(error) =~ "test-api-key"
  end

  test "retries a 429 response and records both attempts on success" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 429, "rate_limit_error", "Slow down")
    end)

    Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, success_body()) end)

    assert {:ok, response} = complete(max_retries: 2)
    assert response.attempts == 2
  end

  test "retries documented conflict errors" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 409, "conflict_error", "Try again")
    end)

    Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, success_body()) end)

    assert {:ok, response} = complete(max_retries: 1)
    assert response.attempts == 2
  end

  test "returns the final 500 after exhausting bounded retries" do
    Req.Test.expect(@stub, 3, fn conn ->
      json_error(conn, 500, "api_error", "Try later", "req_server_error")
    end)

    assert {:error, error} = complete(max_retries: 2)

    assert error["type"] == "provider_unavailable"
    assert error["retryable"]
    assert error["details"]["status"] == 500
    assert error["details"]["attempts"] == 3
    assert error["details"]["max_retries"] == 2
    assert error["details"]["retries_exhausted"]
    assert error["details"]["request_id"] == "req_server_error"
  end

  test "returns an overloaded error after exhausting retries on 529" do
    Req.Test.expect(@stub, 3, fn conn ->
      json_error(conn, 529, "overloaded_error", "Try later", "req_overloaded")
    end)

    assert {:error, error} = complete(max_retries: 2)

    assert error["type"] == "provider_unavailable"
    assert error["retryable"]
    assert error["details"]["status"] == 529
    assert error["details"]["attempts"] == 3
    assert error["details"]["max_retries"] == 2
    assert error["details"]["retries_exhausted"]
    assert error["details"]["request_id"] == "req_overloaded"
  end

  test "retries timeouts and returns a structured exhaustion error" do
    Req.Test.expect(@stub, 2, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, error} = complete(max_retries: 1)

    assert error["type"] == "timeout"
    assert error["message"] == "Anthropic request timed out"
    assert error["retryable"]
    assert error["details"]["reason"] == ":timeout"
    assert error["details"]["attempts"] == 2
    assert error["details"]["retries_exhausted"]
  end

  test "returns a structured decode error for malformed JSON" do
    Req.Test.expect(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{not-json")
    end)

    assert {:error, error} = complete()
    assert error["type"] == "decode_error"
    assert error["details"]["attempts"] == 1
    refute error["retryable"]
  end

  test "returns a structured API error embedded in a successful HTTP response" do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, %{
        "type" => "error",
        "error" => %{"type" => "api_error", "message" => "Unexpected failure"},
        "request_id" => "req_embedded"
      })
    end)

    assert {:error, error} = complete()
    assert error["type"] == "api_error"
    assert error["message"] == "Unexpected failure"
    assert error["details"]["provider_type"] == "api_error"
    assert error["details"]["request_id"] == "req_embedded"
  end

  test "returns structured malformed-response errors instead of raising" do
    scenarios = [
      {"model", Map.delete(success_body(), "model")},
      {"content", Map.delete(success_body(), "content")},
      {"content.text", success_body(%{"content" => [%{"type" => "text", "text" => 7}]})},
      {"usage", Map.put(success_body(), "usage", %{"input_tokens" => 1})},
      {"usage.cache_read_input_tokens",
       success_body(%{
         "usage" => %{
           "input_tokens" => 1,
           "output_tokens" => 2,
           "cache_read_input_tokens" => "unknown"
         }
       })},
      {"stop_reason", Map.delete(success_body(), "stop_reason")}
    ]

    for {field, body} <- scenarios do
      Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, body) end)

      assert {:error,
              %{
                "type" => "malformed_response",
                "details" => %{"field" => ^field, "attempts" => 1}
              }} = complete()
    end
  end

  test "rejects unsupported generation options and unsafe Req options before a request" do
    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"unsupported_options" => ["reasoning"]}
            }} = complete(reasoning: %{"effort" => "low"})

    assert {:error, %{"type" => "configuration_error"}} =
             complete(req_options: [url: "https://example.invalid"])

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"maximum" => 5}
            }} = complete(max_retries: 6)
  end

  test "returns configuration errors for malformed option values instead of raising" do
    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "options"}
            }} = Anthropic.complete(case_definition(), [:not_a_keyword])

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "req_options"}
            }} =
             Anthropic.complete(case_definition(),
               model: "requested-model",
               api_key: "test-api-key",
               max_output_tokens: 256,
               req_options: [:not_a_keyword]
             )

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "temperature"}
            }} = complete(temperature: 1.1)

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "stop_sequences"}
            }} = complete(stop_sequences: [])
  end

  defp complete(overrides \\ []) do
    options =
      [
        model: "requested-model",
        api_key: "test-api-key",
        max_output_tokens: 256,
        max_retries: 2,
        retry_delay_ms: 0,
        req_options: req_options()
      ]
      |> Keyword.merge(overrides)

    Anthropic.complete(case_definition(), options)
  end

  defp case_definition do
    SpikeFixtures.case_definition(%{
      system_prompt: "Use only the supplied context.",
      context: "Frozen source material",
      question: "What happened?",
      response_format: "Answer concisely."
    })
  end

  defp req_options, do: [plug: {Req.Test, @stub}]

  defp decoded_request_body(conn) do
    conn
    |> Req.Test.raw_body()
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  defp success_body(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "requested-model",
        "content" => [%{"type" => "text", "text" => "Grounded answer."}],
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{
          "input_tokens" => 91,
          "cache_creation_input_tokens" => 7,
          "cache_read_input_tokens" => 3,
          "output_tokens" => 12
        }
      },
      overrides
    )
  end

  defp json_error(conn, status, type, message, request_id \\ "req_error") do
    conn
    |> Plug.Conn.put_status(status)
    |> Plug.Conn.put_resp_header("request-id", request_id)
    |> Req.Test.json(%{
      "type" => "error",
      "error" => %{"type" => type, "message" => message},
      "request_id" => request_id
    })
  end
end
