defmodule Mix.Tasks.DriftSpike.ReviewSemanticPairsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.ReviewSemanticPairs
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureDraft
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFixtures

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  @tag :tmp_dir
  test "prints a read-only review page only for the exact source artifact", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "control.json")
    fixture_path = Path.join(tmp_dir, "pairs.json")
    source = distinct_control("review-control")
    :ok = Storage.write(source_path, source)
    source_hash = file_sha256(source_path)
    {:ok, fixture_set} = PairedFixtureDraft.build(source, source_hash, "tuning")
    :ok = SemanticStorage.write(fixture_path, fixture_set)

    arguments = [
      "--fixtures",
      fixture_path,
      "--source",
      source_path,
      "--from",
      "6",
      "--count",
      "1"
    ]

    output = capture_io(fn -> ReviewSemanticPairs.run(arguments) end)
    assert output =~ "Review page: parents 6-6 of 20"
    assert output =~ "source sample 5"
    assert output =~ "tuning-open-synthesis-05-meaning-preserving"
    assert output =~ "Provider calls: 0"
    assert output =~ "Artifacts changed: 0"

    File.write!(source_path, File.read!(source_path) <> "\n")

    assert_raise Mix.Error, ~r/SHA-256 does not match/, fn ->
      capture_io(fn -> ReviewSemanticPairs.run(arguments) end)
    end
  end

  defp distinct_control(run_id) do
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
            output <> "\n\nDistinct source #{sample["sample_index"]}."
          end)
        else
          sample
        end
      end)

    %{run | samples: samples}
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
