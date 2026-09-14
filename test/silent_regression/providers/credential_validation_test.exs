defmodule SilentRegression.Providers.CredentialValidationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SilentRegression.Providers.{Anthropic, OpenAI}

  @openai_stub Module.concat(__MODULE__, OpenAIStub)
  @anthropic_stub Module.concat(__MODULE__, AnthropicStub)
  @sentinel_secret "sk-test-never-return-or-log-this-secret"

  setup {Req.Test, :verify_on_exit!}

  test "adapters declare stable, non-secret request provenance" do
    assert OpenAI.request_provenance() == %{
             api_endpoint: "https://api.openai.com/v1/models",
             api_version: "v1",
             http_method: "GET"
           }

    assert Anthropic.request_provenance() == %{
             api_endpoint: "https://api.anthropic.com/v1/models",
             api_version: "2023-06-01",
             http_method: "GET"
           }
  end

  test "OpenAI validates a credential with one non-generative Models request" do
    Req.Test.expect(@openai_stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/models"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@sentinel_secret}"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req_openai_validation")
      |> Req.Test.json(%{"object" => "list", "data" => [%{"id" => "gpt-test"}]})
    end)

    assert {:ok, result} = OpenAI.validate_credential(@sentinel_secret, openai_options())
    assert result.provider == :openai
    assert result.requested_model == nil
    assert result.returned_model == "gpt-test"
    assert result.request_id == "req_openai_validation"
    assert result.attempts == 1
    refute inspect(result) =~ @sentinel_secret
  end

  test "Anthropic validates access to a specific model with safe provenance" do
    Req.Test.expect(@anthropic_stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/models/claude-test"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [@sentinel_secret]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

      conn
      |> Plug.Conn.put_resp_header("request-id", "req_anthropic_validation")
      |> Req.Test.json(%{"id" => "claude-test", "type" => "model"})
    end)

    assert {:ok, result} =
             Anthropic.validate_credential(
               @sentinel_secret,
               anthropic_options(model: "claude-test")
             )

    assert result.provider == :anthropic
    assert result.requested_model == "claude-test"
    assert result.returned_model == "claude-test"
    assert result.request_id == "req_anthropic_validation"
    refute inspect(result) =~ @sentinel_secret
  end

  test "adapters normalize authorization, rate limit, and provider failures without response bodies" do
    cases = [
      {OpenAI, @openai_stub, 403, :authorization, "x-request-id"},
      {OpenAI, @openai_stub, 429, :rate_limited, "x-request-id"},
      {Anthropic, @anthropic_stub, 500, :provider, "request-id"}
    ]

    for {adapter, stub, status, category, request_header} <- cases do
      request_id = "req_#{status}"

      Req.Test.expect(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header(request_header, request_id)
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"error" => %{"message" => @sentinel_secret}})
      end)

      options = if adapter == OpenAI, do: openai_options(), else: anthropic_options()

      assert {:error, failure} = adapter.validate_credential(@sentinel_secret, options)
      assert failure.category == category
      assert failure.request_id == request_id
      assert failure.attempts == 1
      refute inspect(failure) =~ @sentinel_secret
    end
  end

  test "malformed success, alias resolution, and transport errors are normalized" do
    Req.Test.expect(@openai_stub, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

    assert {:error, malformed} = OpenAI.validate_credential(@sentinel_secret, openai_options())
    assert malformed.category == :malformed_response

    Req.Test.expect(@anthropic_stub, fn conn -> Req.Test.json(conn, %{"id" => "other-model"}) end)

    assert {:ok, resolved_alias} =
             Anthropic.validate_credential(
               @sentinel_secret,
               anthropic_options(model: "requested-model")
             )

    assert resolved_alias.requested_model == "requested-model"
    assert resolved_alias.returned_model == "other-model"
    assert resolved_alias.request_id == nil

    Req.Test.expect(@openai_stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, transport} =
             OpenAI.validate_credential(@sentinel_secret, openai_options())

    assert transport.category == :transport
    assert transport.attempts == 1
  end

  test "unsafe request options are rejected before a provider request" do
    test_pid = self()

    Req.Test.stub(@openai_stub, fn conn ->
      send(test_pid, :unexpected_provider_request)
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:error, failure} =
             OpenAI.validate_credential(@sentinel_secret,
               req_options: [plug: {Req.Test, @openai_stub}, url: "https://example.invalid"]
             )

    assert failure.category == :provider
    refute_received :unexpected_provider_request
  end

  test "malformed JSON and provider error bodies never leak credential material to logs or results" do
    test_pid = self()

    Req.Test.expect(@openai_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{not-json")
    end)

    malformed_log =
      capture_log(fn ->
        send(
          test_pid,
          {:malformed_result, OpenAI.validate_credential(@sentinel_secret, openai_options())}
        )
      end)

    assert_receive {:malformed_result, {:error, malformed}}
    assert malformed.category == :malformed_response
    refute malformed_log =~ @sentinel_secret
    refute inspect(malformed) =~ @sentinel_secret

    Req.Test.expect(@anthropic_stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"message" => @sentinel_secret}})
    end)

    provider_log =
      capture_log(fn ->
        send(
          test_pid,
          {:provider_result, Anthropic.validate_credential(@sentinel_secret, anthropic_options())}
        )
      end)

    assert_receive {:provider_result, {:error, rejected}}
    assert rejected.category == :authentication
    refute provider_log =~ @sentinel_secret
    refute inspect(rejected) =~ @sentinel_secret
  end

  defp openai_options(overrides \\ []) do
    Keyword.merge([req_options: [plug: {Req.Test, @openai_stub}]], overrides)
  end

  defp anthropic_options(overrides \\ []) do
    Keyword.merge([req_options: [plug: {Req.Test, @anthropic_stub}]], overrides)
  end
end
