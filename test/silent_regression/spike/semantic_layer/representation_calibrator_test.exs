defmodule SilentRegression.Spike.SemanticLayer.RepresentationCalibratorTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.Representation.WordNgram
  alias SilentRegression.Spike.SemanticLayer.RepresentationCalibrator
  alias SilentRegression.Spike.SemanticLayer.Storage
  alias SilentRegression.SpikeFixtures

  test "builds reproducible spec, fitted model, and frozen null calibration" do
    baseline = source("baseline", "baseline", baseline_outputs())
    controls = [source("control-1", "control", control_outputs())]

    options = [
      case_id: "rag_open_synthesis",
      excluded_run_ids: ["tuning-control", "heldout-control"],
      seed: 7,
      iterations: 40,
      quantile: 0.95,
      adjusted_p_alpha: 0.05,
      clock: fn -> ~U[2026-09-11 12:00:00Z] end,
      git_revision: "abc123"
    ]

    assert {:ok, first} = RepresentationCalibrator.build(WordNgram, baseline, controls, options)
    assert {:ok, second} = RepresentationCalibrator.build(WordNgram, baseline, controls, options)
    assert first == second

    assert first.spec.fit_policy["fixture_labels_used"] == false
    assert length(first.spec.fit_observation_ids) == 8
    assert first.model.document_count == 8
    assert first.calibration.status == "frozen"
    assert first.calibration.representation["artifact_sha256"] == first.spec_sha256
    assert hd(first.calibration.thresholds)["iterations"] == 40
    assert {:ok, first.spec_sha256} == Storage.sha256(first.spec)
    assert {:ok, first.calibration_sha256} == Storage.sha256(first.calibration)
  end

  test "refuses reserved controls and incompatible provenance" do
    baseline = source("baseline", "baseline", baseline_outputs())
    reserved = source("tuning-control", "control", control_outputs())

    assert {:error, %{type: :reserved_run_cannot_be_a_fit_source}} =
             RepresentationCalibrator.build(WordNgram, baseline, [reserved],
               case_id: "rag_open_synthesis",
               excluded_run_ids: ["tuning-control"]
             )

    incompatible =
      source("other", "control", control_outputs(), requested_model: "other-model")

    assert {:error, %{"type" => "incompatible_provenance"}} =
             RepresentationCalibrator.build(WordNgram, baseline, [incompatible],
               case_id: "rag_open_synthesis"
             )
  end

  defp source(run_id, condition, outputs, options \\ []) do
    run =
      SpikeFixtures.analyzed_run(%{
        run_id: run_id,
        condition: condition,
        outputs: outputs,
        requested_model: Keyword.get(options, :requested_model, "fake-model")
      })

    %{run: run, artifact_sha256: hash(run_id)}
  end

  defp baseline_outputs, do: ["alpha one", "alpha two", "alpha three", "alpha four"]
  defp control_outputs, do: ["one alpha", "two alpha", "three alpha", "four alpha"]

  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
