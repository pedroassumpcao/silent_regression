defmodule Mix.Tasks.DriftSpike.PreflightTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.Preflight

  setup do
    previous_key = System.get_env("OPENAI_API_KEY")
    previous_shell = Mix.shell()

    System.put_env("OPENAI_API_KEY", "preflight-test-secret")
    Mix.shell(Mix.Shell.IO)

    on_exit(fn ->
      restore_environment("OPENAI_API_KEY", previous_key)
      Mix.shell(previous_shell)
    end)
  end

  test "prints an exact all-case plan without exposing the API key" do
    output =
      capture_io(fn ->
        Preflight.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--max-output-tokens",
          "256",
          "--samples",
          "2",
          "--max-retries",
          "1",
          "--max-calls",
          "16",
          "--dry-run"
        ])
      end)

    assert output =~ "Drift spike preflight (dry run)"
    assert output =~ "Provider: openai"
    assert output =~ "Model: explicit-model"
    assert output =~ "Cases (4):"
    assert output =~ "rag_structured_extract"
    assert output =~ "rag_answer_with_citations"
    assert output =~ "rag_abstain_when_unsupported"
    assert output =~ "rag_open_synthesis"
    assert output =~ "Samples per case: 2"
    assert output =~ "Planned samples: 8"
    assert output =~ "Initial provider calls: 8"
    assert output =~ "Retry calls reserved: 8"
    assert output =~ "Maximum provider calls: 16"
    assert output =~ "Approved --max-calls cap: 16"
    assert output =~ "Concurrency: 3"
    assert output =~ ~s(max_output_tokens: 256)
    assert output =~ ~s(max_retries: 1)
    assert output =~ ~s(model: "explicit-model")
    assert output =~ "Credential: OPENAI_API_KEY is present"
    assert output =~ "No provider requests were made."
    refute output =~ "preflight-test-secret"
  end

  test "prints selected cases in requested order" do
    output =
      capture_io(fn ->
        Preflight.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--case",
          "rag_open_synthesis",
          "--case",
          "rag_structured_extract",
          "--max-output-tokens",
          "128",
          "--max-calls",
          "2"
        ])
      end)

    assert output =~ "Cases (2):"
    assert output =~ "Initial provider calls: 2"

    {open_synthesis_position, _length} = :binary.match(output, "rag_open_synthesis")
    {structured_position, _length} = :binary.match(output, "rag_structured_extract")
    assert open_synthesis_position < structured_position
  end

  test "refuses a cap that cannot cover the configured retry reserve" do
    assert_raise Mix.Error, ~r/Planned calls and retry reserve exceed the max-calls cap/, fn ->
      capture_io(fn ->
        Preflight.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--case",
          "rag_structured_extract",
          "--max-output-tokens",
          "128",
          "--samples",
          "2",
          "--max-retries",
          "1",
          "--max-calls",
          "3"
        ])
      end)
    end
  end

  test "requires the provider credential to be present" do
    System.delete_env("OPENAI_API_KEY")

    assert_raise Mix.Error, ~r/OPENAI_API_KEY/, fn ->
      capture_io(fn ->
        Preflight.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--max-output-tokens",
          "128",
          "--max-calls",
          "4"
        ])
      end)
    end
  end

  test "rejects missing required arguments and unknown cases" do
    assert_raise Mix.Error, ~r/--max-calls is required/, fn ->
      capture_io(fn ->
        Preflight.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--max-output-tokens",
          "128"
        ])
      end)
    end

    assert_raise Mix.Error, ~r/Unknown spike case/, fn ->
      capture_io(fn ->
        Preflight.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--case",
          "unknown-case",
          "--max-output-tokens",
          "128",
          "--max-calls",
          "1"
        ])
      end)
    end
  end

  defp restore_environment(name, nil), do: System.delete_env(name)
  defp restore_environment(name, value), do: System.put_env(name, value)
end
