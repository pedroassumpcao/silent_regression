defmodule Mix.Tasks.DriftSpike.ControlTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.Control
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFixtures

  setup do
    previous_key = System.get_env("OPENAI_API_KEY")
    previous_shell = Mix.shell()

    System.put_env("OPENAI_API_KEY", "control-test-secret")
    Mix.shell(Mix.Shell.IO)

    on_exit(fn ->
      restore_environment("OPENAI_API_KEY", previous_key)
      Mix.shell(previous_shell)
    end)
  end

  @tag :tmp_dir
  test "prints the default control budget and performs a call-free dry run", %{tmp_dir: tmp_dir} do
    baseline_path = write_openai_baseline(tmp_dir)
    output_path = Path.join(tmp_dir, "control.json")

    output =
      capture_io(fn ->
        Control.run([
          "--baseline",
          baseline_path,
          "--provider",
          "openai",
          "--model",
          "explicit-model",
          "--max-output-tokens",
          "512",
          "--max-calls",
          "21",
          "--seed",
          "20260907",
          "--output",
          output_path,
          "--dry-run"
        ])
      end)

    assert output =~ "Drift spike control (dry run)"
    assert output =~ "Baseline: openai-baseline"
    assert output =~ "Provider: openai"
    assert output =~ "Model: explicit-model"
    assert output =~ "Samples per case: 20"
    assert output =~ "Planned samples: 20"
    assert output =~ "Model availability calls: 1"
    assert output =~ "Maximum provider calls: 21"
    assert output =~ "Comparison seed: 20260907"
    assert output =~ "Permutations per case: 999"
    assert output =~ "Calibration: none (report only)"
    assert output =~ "No provider requests were made and no artifact was written."
    refute output =~ "control-test-secret"
    refute File.exists?(output_path)
  end

  @tag :tmp_dir
  test "rejects an incompatible model before a dry run can proceed", %{tmp_dir: tmp_dir} do
    baseline_path = write_openai_baseline(tmp_dir)

    assert_raise Mix.Error, ~r/Run provenance is incompatible/, fn ->
      capture_io(fn ->
        Control.run([
          "--baseline",
          baseline_path,
          "--provider",
          "openai",
          "--model",
          "different-model",
          "--max-output-tokens",
          "512",
          "--max-calls",
          "21",
          "--seed",
          "1",
          "--dry-run"
        ])
      end)
    end
  end

  @tag :tmp_dir
  test "previews calibration from persisted controls without calls or writes", %{tmp_dir: tmp_dir} do
    baseline =
      SpikeFixtures.analyzed_run(%{
        run_id: "baseline",
        outputs: ["red apple", "red fruit", "apple fruit", "red berry"]
      })

    control =
      SpikeFixtures.analyzed_run(%{
        run_id: "control",
        condition: "control",
        outputs: ["apple red", "fruit red", "fruit apple", "berry red"]
      })

    baseline_path = Path.join(tmp_dir, "baseline.json")
    control_path = Path.join(tmp_dir, "control.json")
    calibration_path = Path.join(tmp_dir, "calibration.json")
    :ok = Storage.write(baseline_path, baseline)
    :ok = Storage.write(control_path, control)

    output =
      capture_io(fn ->
        Control.run([
          "--calibrate",
          "--baseline",
          baseline_path,
          "--control",
          control_path,
          "--seed",
          "82",
          "--iterations",
          "20",
          "--output",
          calibration_path,
          "--dry-run"
        ])
      end)

    assert output =~ "Drift spike calibration (dry run)"
    assert output =~ "Baseline: baseline"
    assert output =~ "Controls (1):"
    assert output =~ "control"
    assert output =~ "Seed: 82"
    assert output =~ "Iterations per case: 20"
    assert output =~ "rag_open_synthesis"
    assert output =~ "No provider requests were made and no artifact was written."
    refute File.exists?(calibration_path)
  end

  defp write_openai_baseline(tmp_dir) do
    baseline =
      SpikeFixtures.analyzed_run(%{
        run_id: "openai-baseline",
        provider: "openai",
        requested_model: "explicit-model",
        returned_model: "explicit-model",
        request_config: %{"api_endpoint" => "https://api.openai.com/v1/responses"},
        outputs: ["red apple", "apple red"]
      })

    path = Path.join(tmp_dir, "openai-baseline.json")
    :ok = Storage.write(path, baseline)
    path
  end

  defp restore_environment(name, nil), do: System.delete_env(name)
  defp restore_environment(name, value), do: System.put_env(name, value)
end
