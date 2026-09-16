defmodule SilentRegression.RunResults.SafeValueTest do
  use ExUnit.Case, async: true

  alias SilentRegression.RunResults.SafeValue

  test "bounds UTF-8 text without producing an invalid prefix" do
    value = String.duplicate("🙂", 20)

    assert %{text: preview, truncated: true, original_bytes: 80} = SafeValue.text(value, 13)
    assert String.valid?(preview)
    assert byte_size(preview) <= 13
    assert preview == "🙂🙂🙂"
  end

  test "keeps executable-looking customer content inert and redacts sensitive structured keys" do
    script = ~s(<script>globalThis.compromised = true</script>)

    assert %{text: ^script, truncated: false} = SafeValue.text(script)

    assert SafeValue.diagnostic(%{
             "authorization" => "Bearer secret",
             "nested" => %{"api_key" => "sk-secret", "status" => 401},
             "input_tokens" => 42
           }) == %{
             "authorization" => "[REDACTED]",
             "nested" => %{"api_key" => "[REDACTED]", "status" => 401},
             "input_tokens" => 42
           }
  end

  test "allowlists provider metadata instead of forwarding arbitrary response values" do
    assert SafeValue.provider_metadata(%{
             "api_version" => "v1",
             "client_request_id" => "safe-id",
             "secret" => "do-not-forward",
             "response_body" => %{"prompt" => "do-not-forward"}
           }) == %{
             "api_version" => "v1",
             "client_request_id" => "safe-id"
           }
  end
end
