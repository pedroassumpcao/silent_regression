defmodule SilentRegression.Spike.ProviderTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Provider

  test "builds a structured provider error with explicit retry metadata" do
    assert Provider.error(:rate_limited, "Provider rejected the request",
             retryable?: true,
             details: %{"status" => 429}
           ) == %{
             "type" => "rate_limited",
             "message" => "Provider rejected the request",
             "retryable" => true,
             "details" => %{"status" => 429}
           }
  end

  test "provider errors are non-retryable by default" do
    assert %{"retryable" => false, "details" => %{}} =
             Provider.error(:invalid_request, "Invalid request")
  end

  test "rejects error details that cannot be persisted" do
    assert_raise ArgumentError, fn ->
      Provider.error(:http_error, "Request failed", details: %{status: 500})
    end
  end
end
