defmodule SilentRegression.Providers.CompletionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SilentRegression.Providers.{Anthropic, CompletionRequest, OpenAI, RequestArtifact}

  @openai_stub Module.concat(__MODULE__, OpenAIStub)
  @anthropic_stub Module.concat(__MODULE__, AnthropicStub)
  @secret "sk-test-never-persist-this-secret"

  setup {Req.Test, :verify_on_exit!}

  test "OpenAI performs exactly one traceable Responses request and drops the raw body" do
    Req.Test.expect(@openai_stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/responses"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@secret}"]
      assert Plug.Conn.get_req_header(conn, "x-client-request-id") == ["client-attempt-1"]

      body = decoded_request_body(conn)
      assert body["model"] == "gpt-5.6-luna"
      assert body["store"] == false
      assert body["instructions"] == "Use only supplied evidence."
      assert body["max_output_tokens"] == 256
      refute Map.has_key?(body, "temperature")
      assert body["text"] == %{"format" => %{"type" => "json_object"}}

      assert body["input"] == [
               %{
                 "role" => "user",
                 "content" =>
                   "Evidence: The Enterprise plan includes SSO.\nQuestion: Which plan includes SSO?"
               }
             ]

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "request-openai-1")
      |> Req.Test.json(%{
        "id" => "response-openai-1",
        "model" => "gpt-5.6-luna-2026-09-01",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => ~s({"label":"approved"})}]
          }
        ],
        "usage" => %{"input_tokens" => 20, "output_tokens" => 5},
        "sensitive_debug" => @secret
      })
    end)

    assert {:ok, result} =
             OpenAI.complete_once(@secret, request(:openai), req_options(@openai_stub))

    assert result.provider == :openai
    assert result.returned_model == "gpt-5.6-luna-2026-09-01"
    assert result.output_text == ~s({"label":"approved"})
    assert result.request_id == "response-openai-1"
    assert result.completion_state == :complete
    assert result.input_tokens == 20
    assert result.output_tokens == 5

    assert result.metadata == %{
             "api_endpoint" => "https://api.openai.com/v1/responses",
             "api_version" => "v1",
             "client_request_id" => "client-attempt-1",
             "http_method" => "POST",
             "model_mismatch" => true
           }

    refute inspect(result) =~ @secret
    refute Map.has_key?(result.metadata, "sensitive_debug")
  end

  test "Anthropic normalizes incomplete Messages evidence without retaining the response body" do
    Req.Test.expect(@anthropic_stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [@secret]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

      body = decoded_request_body(conn)
      assert body["model"] == "claude-haiku-4-5-20251001"
      assert body["max_tokens"] == 256
      assert body["system"] == "Use only supplied evidence."

      conn
      |> Plug.Conn.put_resp_header("request-id", "request-anthropic-1")
      |> Req.Test.json(%{
        "id" => "message-anthropic-1",
        "model" => "claude-haiku-4-5-20251001",
        "content" => [%{"type" => "text", "text" => "approved"}],
        "stop_reason" => "max_tokens",
        "usage" => %{
          "input_tokens" => 18,
          "output_tokens" => 4,
          "cache_read_input_tokens" => 2
        },
        "sensitive_debug" => @secret
      })
    end)

    assert {:ok, result} =
             Anthropic.complete_once(
               @secret,
               request(:anthropic),
               req_options(@anthropic_stub)
             )

    assert result.provider == :anthropic
    assert result.request_id == "request-anthropic-1"
    assert result.completion_state == :incomplete
    assert result.finish_reason == "max_tokens"
    assert result.input_tokens == 20
    assert result.output_tokens == 4
    refute inspect(result) =~ @secret
  end

  test "a retryable provider response is returned after one request for durable accounting" do
    Req.Test.expect(@openai_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-request-id", "request-rate-limit")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "error" => %{
          "message" => @secret,
          "type" => "rate_limit_error",
          "code" => "rate_limit_exceeded",
          "param" => "model"
        }
      })
    end)

    log =
      capture_log(fn ->
        assert {:error, failure} =
                 OpenAI.complete_once(@secret, request(:openai), req_options(@openai_stub))

        assert failure.category == :rate_limited
        assert failure.retryable
        assert failure.attempts == 1
        assert failure.request_id == "request-rate-limit"
        assert failure.latency_ms >= 0

        assert failure.metadata == %{
                 "attempts" => 1,
                 "max_retries" => 0,
                 "provider_code" => "rate_limit_exceeded",
                 "provider_param" => "model",
                 "provider_type" => "rate_limit_error",
                 "retries_exhausted" => true,
                 "status" => 429
               }

        refute inspect(failure) =~ @secret
      end)

    refute log =~ @secret
  end

  test "rejects a tampered request artifact before making an HTTP request" do
    request = request(:openai)

    tampered = %{
      request
      | request_artifact: put_in(request.request_artifact, ["body", "temperature"], 0.0)
    }

    assert {:error, failure} =
             OpenAI.complete_once(@secret, tampered, req_options(@openai_stub))

    assert failure.category == :invalid_request
    assert failure.request_id == nil
    assert failure.attempts == 1
  end

  defp request(provider) do
    {:ok, built} =
      RequestArtifact.build(
        %{
          provider: provider,
          requested_model: requested_model(provider),
          request_mode: :provider_native_v1,
          request_schema_version: 1,
          request_template: request_template(provider),
          system_prompt: "",
          user_prompt_template: "",
          response_format: response_format(provider),
          generation_config: %{"max_output_tokens" => 256}
        },
        %{
          input_variables: %{"question" => "Which plan includes SSO?"},
          frozen_context: "The Enterprise plan includes SSO."
        }
      )

    %CompletionRequest{
      case_id: "supported-answer",
      attempt_number: 1,
      requested_model: requested_model(provider),
      request_mode: built.mode,
      request_schema_version: built.schema_version,
      request_artifact: built.artifact,
      request_fingerprint: built.fingerprint,
      client_request_id: "client-attempt-1"
    }
  end

  defp request_template(:openai) do
    %{
      "instructions" => "Use only supplied evidence.",
      "input" => [
        %{
          "role" => "user",
          "content" => "Evidence: {{frozen_context}}\nQuestion: {{question}}"
        }
      ]
    }
  end

  defp request_template(:anthropic) do
    %{
      "system" => "Use only supplied evidence.",
      "messages" => [
        %{
          "role" => "user",
          "content" => "Evidence: {{frozen_context}}\nQuestion: {{question}}"
        }
      ]
    }
  end

  defp response_format(:openai), do: %{"type" => "json_object"}
  defp response_format(:anthropic), do: %{"type" => "text"}

  defp requested_model(:openai), do: "gpt-5.6-luna"
  defp requested_model(:anthropic), do: "claude-haiku-4-5-20251001"

  defp req_options(stub), do: [req_options: [plug: {Req.Test, stub}]]

  defp decoded_request_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
