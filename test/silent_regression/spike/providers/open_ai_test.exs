defmodule SilentRegression.Spike.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Providers.OpenAI
  alias SilentRegression.Spike.Response
  alias SilentRegression.SpikeFixtures

  @stub __MODULE__

  setup {Req.Test, :verify_on_exit!}

  test "identifies the provider" do
    assert OpenAI.id() == "openai"
  end

  test "posts a stateless Responses API request and normalizes every response field" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/responses"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-api-key"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      body = decoded_request_body(conn)
      assert body["model"] == "requested-model"
      assert body["store"] == false
      assert body["instructions"] == "Use only the supplied context."
      assert body["max_output_tokens"] == 256
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "top_p")

      [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => input}]}] =
        body["input"]

      assert input =~ "Context:\nFrozen source material"
      assert input =~ "Question:\nWhat happened?"
      assert input =~ "Response requirements:\nAnswer concisely."

      Req.Test.json(conn, success_body())
    end)

    before_call = DateTime.utc_now()

    assert {:ok, %Response{} = response} =
             OpenAI.complete(case_definition(),
               model: "requested-model",
               api_key: "test-api-key",
               max_output_tokens: 256,
               req_options: req_options()
             )

    assert response.provider == "openai"
    assert response.requested_model == "requested-model"
    assert response.returned_model == "requested-model"
    assert response.output_text == "Grounded answer."
    assert response.request_id == "resp_123"
    assert response.usage == %{"input_tokens" => 91, "output_tokens" => 12}
    assert response.latency_ms >= 0
    assert response.finish_reason == "completed"
    assert DateTime.compare(response.captured_at, before_call) in [:eq, :gt]
    assert response.raw == success_body()
    assert response.attempts == 1
  end

  test "walks multiple output item and content block shapes in order" do
    output = [
      %{"type" => "reasoning", "id" => "reasoning_1"},
      %{
        "type" => "message",
        "content" => [
          %{"type" => "output_text", "text" => "First paragraph."},
          %{"type" => "refusal", "refusal" => "A limited refusal."},
          %{"type" => "annotation", "text" => "ignored"}
        ]
      },
      %{"type" => "function_call", "name" => "ignored"},
      %{"type" => "output_text", "text" => "Final paragraph."}
    ]

    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(
        conn,
        success_body(%{"output" => output, "output_text" => "must not be duplicated"})
      )
    end)

    assert {:ok, response} = complete()

    assert response.output_text ==
             "First paragraph.\nA limited refusal.\nFinal paragraph."
  end

  test "uses top-level output_text when no output content block contains text" do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(
        conn,
        success_body(%{
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"},
          "output" => [%{"type" => "reasoning"}],
          "output_text" => "Partial answer."
        })
      )
    end)

    assert {:ok, response} = complete()
    assert response.output_text == "Partial answer."
    assert response.finish_reason == "incomplete:max_output_tokens"
  end

  test "records requested and returned model IDs when they differ" do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, success_body(%{"model" => "effective-model-snapshot"}))
    end)

    assert {:ok, response} = complete(model: "requested-model-alias")
    assert response.requested_model == "requested-model-alias"
    assert response.returned_model == "effective-model-snapshot"
  end

  test "includes generation parameters only when explicitly supplied" do
    Req.Test.expect(@stub, fn conn ->
      body = decoded_request_body(conn)
      assert body["temperature"] == 0.4
      assert body["top_p"] == 0.9
      assert body["reasoning"] == %{"effort" => "low"}
      assert body["text"] == %{"format" => %{"type" => "text"}}

      Req.Test.json(conn, success_body())
    end)

    assert {:ok, _response} =
             complete(
               temperature: 0.4,
               top_p: 0.9,
               reasoning: %{"effort" => "low"},
               text: %{"format" => %{"type" => "text"}}
             )
  end

  test "missing model and missing API key fail before any HTTP request" do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, :unexpected_openai_request)
      Req.Test.json(conn, success_body())
    end)

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "model"}
            }} =
             OpenAI.complete(case_definition(),
               api_key: "test-api-key",
               req_options: req_options()
             )

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "api_key"}
            }} =
             OpenAI.complete(case_definition(),
               model: "requested-model",
               api_key: "",
               req_options: req_options()
             )

    refute_received :unexpected_openai_request
  end

  test "a 400 response is structured and is not retried" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 400, "invalid_request_error", "invalid_value", "Bad input", "input")
    end)

    assert {:error, error} = complete(max_retries: 2)

    assert error["type"] == "invalid_request"
    assert error["message"] == "Bad input"
    refute error["retryable"]
    assert error["details"]["status"] == 400
    assert error["details"]["attempts"] == 1
    assert error["details"]["provider_type"] == "invalid_request_error"
    assert error["details"]["provider_code"] == "invalid_value"
    assert error["details"]["provider_param"] == "input"
  end

  test "a 401 response is structured without exposing the API key" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 401, "invalid_request_error", "invalid_api_key", "Invalid key")
    end)

    assert {:error, error} = complete()

    assert error["type"] == "authentication_error"
    refute error["retryable"]
    assert error["details"]["attempts"] == 1
    refute inspect(error) =~ "test-api-key"
  end

  test "retries a 429 response and records both attempts on success" do
    Req.Test.expect(@stub, fn conn ->
      json_error(conn, 429, "rate_limit_error", "rate_limit_exceeded", "Slow down")
    end)

    Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, success_body()) end)

    assert {:ok, response} = complete(max_retries: 2)
    assert response.attempts == 2
  end

  test "returns the final 500 after exhausting bounded retries" do
    Req.Test.expect(@stub, 3, fn conn ->
      json_error(conn, 500, "server_error", "server_error", "Try later")
    end)

    assert {:error, error} = complete(max_retries: 2)

    assert error["type"] == "provider_unavailable"
    assert error["retryable"]
    assert error["details"]["status"] == 500
    assert error["details"]["attempts"] == 3
    assert error["details"]["max_retries"] == 2
    assert error["details"]["retries_exhausted"]
  end

  test "retries timeouts and returns a structured exhaustion error" do
    Req.Test.expect(@stub, 2, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, error} = complete(max_retries: 1)

    assert error["type"] == "timeout"
    assert error["message"] == "OpenAI request timed out"
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

  test "returns structured malformed-response errors instead of raising" do
    scenarios = [
      {"model", Map.delete(success_body(), "model")},
      {"output", Map.delete(success_body(), "output")},
      {"usage", Map.put(success_body(), "usage", %{"input_tokens" => 1})}
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

  test "rejects unsafe Req options and unbounded retry settings before a request" do
    assert {:error, %{"type" => "configuration_error"}} =
             complete(req_options: [url: "https://example.invalid"])

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"maximum" => 5}
            }} = complete(max_retries: 6)
  end

  test "returns configuration errors for malformed option lists instead of raising" do
    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "options"}
            }} = OpenAI.complete(case_definition(), [:not_a_keyword])

    assert {:error,
            %{
              "type" => "configuration_error",
              "details" => %{"field" => "req_options"}
            }} =
             OpenAI.complete(case_definition(),
               model: "requested-model",
               api_key: "test-api-key",
               req_options: [:not_a_keyword]
             )
  end

  defp complete(overrides \\ []) do
    options =
      [
        model: "requested-model",
        api_key: "test-api-key",
        max_retries: 2,
        retry_delay_ms: 0,
        req_options: req_options()
      ]
      |> Keyword.merge(overrides)

    OpenAI.complete(case_definition(), options)
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
        "id" => "resp_123",
        "model" => "requested-model",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Grounded answer."}]
          }
        ],
        "usage" => %{
          "input_tokens" => 91,
          "output_tokens" => 12,
          "total_tokens" => 103,
          "input_tokens_details" => %{"cached_tokens" => 7},
          "output_tokens_details" => %{"reasoning_tokens" => 3}
        }
      },
      overrides
    )
  end

  defp json_error(conn, status, type, code, message, param \\ nil) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(%{
      "error" => %{
        "type" => type,
        "code" => code,
        "message" => message,
        "param" => param
      }
    })
  end
end
