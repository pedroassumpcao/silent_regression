defmodule Mix.Tasks.DriftSpike.DraftSemanticPairsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.DraftSemanticPairs
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFixtures

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  @tag :tmp_dir
  test "validates in dry-run mode and writes two candidate-only artifacts", %{tmp_dir: tmp_dir} do
    tuning_path = Path.join(tmp_dir, "tuning-control.json")
    heldout_path = Path.join(tmp_dir, "heldout-control.json")
    output_directory = Path.join(tmp_dir, "candidates")
    :ok = Storage.write(tuning_path, distinct_control("tuning-control", "tuning"))
    :ok = Storage.write(heldout_path, distinct_control("heldout-control", "heldout"))

    arguments = [
      "--tuning",
      tuning_path,
      "--heldout",
      heldout_path,
      "--output",
      output_directory
    ]

    dry_run_output = capture_io(fn -> DraftSemanticPairs.run(arguments ++ ["--dry-run"]) end)
    assert dry_run_output =~ "Semantic paired fixtures (dry run)"
    assert dry_run_output =~ "Total candidate judgments requiring review: 120"
    assert dry_run_output =~ "Cross-split candidate output overlap: 0"
    assert dry_run_output =~ "parent within-Jaccard mean:"
    assert dry_run_output =~ "within-Jaccard"
    assert dry_run_output =~ "Provider calls: 0"
    refute File.exists?(output_directory)

    output = capture_io(fn -> DraftSemanticPairs.run(arguments) end)
    assert output =~ "Semantic paired fixture candidates captured"
    assert output =~ "All fixtures remain candidates pending explicit human approval."

    tuning_output = Path.join(output_directory, "tuning-pairs.json")
    heldout_output = Path.join(output_directory, "heldout-pairs.json")
    assert {:ok, tuning} = SemanticStorage.read(tuning_output)
    assert {:ok, heldout} = SemanticStorage.read(heldout_output)
    assert tuning.status == "candidate"
    assert heldout.status == "candidate"
    assert length(tuning.fixtures) == 60
    assert length(heldout.fixtures) == 60

    assert_raise Mix.Error, ~r/Refusing to overwrite/, fn ->
      capture_io(fn -> DraftSemanticPairs.run(arguments) end)
    end
  end

  defp distinct_control(run_id, marker) do
    run =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: run_id,
        condition: "control",
        provider: "openai",
        requested_model: "gpt-5.6-luna",
        returned_model: "gpt-5.6-luna",
        sample_size: 20
      })

    samples =
      Enum.map(run.samples, fn sample ->
        if sample["case_id"] == "rag_open_synthesis" do
          update_in(sample, ["response", "output_text"], fn output ->
            output <> "\n\n#{marker} #{sample["sample_index"]}."
          end)
        else
          sample
        end
      end)

    %{run | samples: samples}
  end
end
