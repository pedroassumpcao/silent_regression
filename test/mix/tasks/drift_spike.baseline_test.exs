defmodule Mix.Tasks.DriftSpike.BaselineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.Baseline

  setup do
    previous_key = System.get_env("OPENAI_API_KEY")
    previous_shell = Mix.shell()

    System.put_env("OPENAI_API_KEY", "baseline-test-secret")
    Mix.shell(Mix.Shell.IO)

    on_exit(fn ->
      restore_environment("OPENAI_API_KEY", previous_key)
      Mix.shell(previous_shell)
    end)
  end

  test "prints the exact default baseline budget and performs a call-free dry run" do
    output =
      capture_io(fn ->
        Baseline.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--max-output-tokens",
          "256",
          "--max-calls",
          "121",
          "--dry-run"
        ])
      end)

    assert output =~ "Drift spike baseline (dry run)"
    assert output =~ "Provider: openai"
    assert output =~ "Model: explicit-model"
    assert output =~ "Cases (4):"
    assert output =~ "Samples per case: 30"
    assert output =~ "Planned samples: 120"
    assert output =~ "Model availability calls: 1"
    assert output =~ "Initial generation calls: 120"
    assert output =~ "Retry calls reserved: 0"
    assert output =~ "Maximum provider calls: 121"
    assert output =~ "Approved --max-calls cap: 121"
    assert output =~ "Concurrency: 3"
    assert output =~ ~s(max_output_tokens: 256)
    assert output =~ ~s(max_retries: 0)
    assert output =~ ~s(model: "explicit-model")
    assert output =~ "Credential: OPENAI_API_KEY is present"
    assert output =~ "No provider requests were made and no artifact was written."
    refute output =~ "baseline-test-secret"
  end

  test "prints selected cases and the explicit artifact destination" do
    output =
      capture_io(fn ->
        Baseline.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--case",
          "rag_open_synthesis",
          "--samples",
          "2",
          "--max-output-tokens",
          "128",
          "--max-calls",
          "3",
          "--output",
          "results/drift_spike/custom.json",
          "--label",
          "custom baseline",
          "--dry-run"
        ])
      end)

    assert output =~ "Cases (1):"
    assert output =~ "rag_open_synthesis"
    assert output =~ "Label: custom baseline"
    assert output =~ "Planned samples: 2"
    assert output =~ "Maximum provider calls: 3"
    assert output =~ "Artifact destination: results/drift_spike/custom.json"
  end

  test "refuses a cap that omits the model-access request" do
    assert_raise Mix.Error, ~r/model access, generation calls, and retry reserve/, fn ->
      capture_io(fn ->
        Baseline.run([
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--max-output-tokens",
          "128",
          "--max-calls",
          "120",
          "--dry-run"
        ])
      end)
    end
  end

  defp restore_environment(name, nil), do: System.delete_env(name)
  defp restore_environment(name, value), do: System.put_env(name, value)
end
