defmodule SilentRegression.Spike.ModelAvailabilityTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.ModelAvailability
  alias SilentRegression.Spike.Providers.Anthropic
  alias SilentRegression.Spike.Providers.OpenAI

  @stub __MODULE__

  setup {Req.Test, :verify_on_exit!}

  test "retrieves the exact OpenAI model without exposing credentials" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/models/requested-model"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-api-key"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req_openai_model")
      |> Req.Test.json(%{"id" => "requested-model", "object" => "model"})
    end)

    assert {:ok, result} =
             ModelAvailability.check(OpenAI, "requested-model",
               api_key: "test-api-key",
               req_options: req_options()
             )

    assert result == %{
             "provider" => "openai",
             "requested_model" => "requested-model",
             "returned_model" => "requested-model",
             "request_id" => "req_openai_model",
             "attempts" => 1
           }

    refute inspect(result) =~ "test-api-key"
  end

  test "retrieves the exact Anthropic model with the stable API version" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/models/claude-requested-model"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-api-key"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      conn
      |> Plug.Conn.put_resp_header("request-id", "req_anthropic_model")
      |> Req.Test.json(%{"id" => "claude-requested-model", "type" => "model"})
    end)

    assert {:ok, result} =
             ModelAvailability.check(Anthropic, "claude-requested-model",
               api_key: "test-api-key",
               req_options: req_options()
             )

    assert result["provider"] == "anthropic"
    assert result["returned_model"] == "claude-requested-model"
    assert result["request_id"] == "req_anthropic_model"
    assert result["attempts"] == 1
  end

  test "returns an unavailable error for a non-success response without retrying" do
    Req.Test.expect(@stub, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"error" => %{"message" => "model not found"}})
    end)

    assert {:error, error} =
             ModelAvailability.check(OpenAI, "missing-model",
               api_key: "test-api-key",
               req_options: req_options()
             )

    assert error["type"] == "model_unavailable"
    assert error["details"]["status"] == 404
    assert error["details"]["attempts"] == 1
  end

  test "rejects a successful response for a different model" do
    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, %{"id" => "substitute-model", "object" => "model"})
    end)

    assert {:error, error} =
             ModelAvailability.check(OpenAI, "requested-model",
               api_key: "test-api-key",
               req_options: req_options()
             )

    assert error["type"] == "invalid_model_response"
    assert error["details"]["requested_model"] == "requested-model"
    assert error["details"]["returned_model"] == "substitute-model"
  end

  test "missing credentials fail before an HTTP request" do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, :unexpected_model_request)
      Req.Test.json(conn, %{"id" => "requested-model"})
    end)

    assert {:error, error} =
             ModelAvailability.check(OpenAI, "requested-model",
               environment: %{},
               req_options: req_options()
             )

    assert error["type"] == "configuration_error"
    assert error["details"]["env_var"] == "OPENAI_API_KEY"
    refute_received :unexpected_model_request
  end

  defp req_options, do: [plug: {Req.Test, @stub}]
end
