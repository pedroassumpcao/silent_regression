defmodule Mix.Tasks.DriftSpike.RescoreSemanticContractsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.RescoreSemanticContracts
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage

  @tuning_path "test/fixtures/drift_spike/semantic_layer/approved/tuning-pairs.json"

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  @tag :tmp_dir
  test "previews and captures a call-free immutable rescore", %{tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "tuning-rescore.json")
    arguments = ["--paired", @tuning_path, "--output", output_path]

    dry_run_output =
      capture_io(fn -> RescoreSemanticContracts.run(arguments ++ ["--dry-run"]) end)

    assert dry_run_output =~ "Semantic contract rescore (dry run)"
    assert dry_run_output =~ "Paired split: tuning"
    assert dry_run_output =~ "Matched judgments: 88/88"
    assert dry_run_output =~ "Provider calls: 0"
    refute File.exists?(output_path)

    output = capture_io(fn -> RescoreSemanticContracts.run(arguments) end)
    assert output =~ "Semantic contract rescore captured"
    assert output =~ "Source fixture artifacts were not changed."
    assert {:ok, result} = SemanticStorage.read(output_path)
    assert result.summary["matched_expectation_count"] == 88

    assert_raise Mix.Error, ~r/already_exists/, fn ->
      capture_io(fn -> RescoreSemanticContracts.run(arguments) end)
    end
  end
end
