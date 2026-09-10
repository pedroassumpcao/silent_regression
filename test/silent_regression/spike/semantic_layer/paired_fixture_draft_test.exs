defmodule SilentRegression.Spike.SemanticLayer.PairedFixtureDraftTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.{CaseSet, DeterministicChecks}
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureDraft
  alias SilentRegression.SpikeFixtures

  test "drafts three distinct, traceable candidates for each of 20 unique parents" do
    tuning_run = distinct_control("tuning-control", "tuning source")
    heldout_run = distinct_control("heldout-control", "heldout source")

    assert {:ok, tuning} =
             PairedFixtureDraft.build(tuning_run, hash("tuning"), "tuning",
               clock: fn -> ~U[2026-09-10 19:00:00Z] end,
               git_revision: "abc123"
             )

    assert {:ok, heldout} =
             PairedFixtureDraft.build(heldout_run, hash("heldout"), "heldout",
               clock: fn -> ~U[2026-09-10 19:00:00Z] end,
               git_revision: "abc123"
             )

    for fixture_set <- [tuning, heldout] do
      assert fixture_set.status == "candidate"
      assert length(fixture_set.fixtures) == 60
      assert Enum.all?(fixture_set.fixtures, &(&1["approval"]["status"] == "candidate"))

      assert fixture_set.fixtures
             |> Enum.group_by(& &1["parent_observation_id"])
             |> Enum.all?(fn {_parent_id, fixtures} ->
               Enum.map(fixtures, & &1["label"]) ==
                 ~w(meaning_preserving style_only subtle_regression)
             end)

      assert Enum.all?(fixture_set.duplicate_counts, fn counts ->
               counts["sample_count"] == 20 and counts["unique_parent_count"] == 20 and
                 counts["unique_output_count"] == 20 and counts["duplicate_output_count"] == 0
             end)

      assert Enum.all?(fixture_set.fixtures, fn fixture ->
               fixture["case_id"] == "rag_open_synthesis" and
                 fixture["split"] in ~w(tuning heldout) and
                 byte_size(fixture["parent_output_sha256"]) == 64
             end)
    end

    tuning_outputs = MapSet.new(tuning.fixtures, & &1["output_text"])
    heldout_outputs = MapSet.new(heldout.fixtures, & &1["output_text"])
    assert MapSet.disjoint?(tuning_outputs, heldout_outputs)

    assert Enum.all?(tuning.fixtures, &valid_proposed_judgment?/1)
    assert Enum.all?(heldout.fixtures, &valid_proposed_judgment?/1)
  end

  test "rejects cycled parents and incompatible pilot provenance" do
    control = distinct_control("control", "source")

    repeated_output =
      control.samples
      |> Enum.find(&(&1["case_id"] == "rag_open_synthesis"))
      |> get_in(["response", "output_text"])

    cycled_samples =
      Enum.map(control.samples, fn sample ->
        if sample["case_id"] == "rag_open_synthesis",
          do: put_in(sample, ["response", "output_text"], repeated_output),
          else: sample
      end)

    assert {:error, error} =
             PairedFixtureDraft.build(
               %{control | samples: cycled_samples},
               hash("control"),
               "tuning"
             )

    assert error["type"] == "incompatible_source"
    assert error["message"] =~ "distinct"

    wrong_model =
      distinct_control("wrong-model", "source", requested_model: "different-model")

    assert {:error, error} =
             PairedFixtureDraft.build(wrong_model, hash("wrong"), "heldout")

    assert error["type"] == "incompatible_source"

    assert {:error, error} =
             PairedFixtureDraft.build(control, hash("control"), "authoring")

    assert error["type"] == "configuration_error"
  end

  test "meaning-preserving candidates retain the frozen deterministic contract" do
    control = distinct_control("tuning-control", "tuning source")
    {:ok, fixture_set} = PairedFixtureDraft.build(control, hash("tuning"), "tuning")
    {:ok, case_definition} = CaseSet.fetch("rag_open_synthesis")

    fixture_set.fixtures
    |> Enum.filter(&(&1["label"] == "meaning_preserving"))
    |> Enum.each(fn fixture ->
      assert {:ok, %{"all_passed" => true}} =
               DeterministicChecks.evaluate(case_definition, fixture["output_text"]),
             "expected #{fixture["fixture_id"]} to pass the frozen deterministic contract"
    end)
  end

  defp distinct_control(run_id, marker, overrides \\ []) do
    requested_model = Keyword.get(overrides, :requested_model, "gpt-5.6-luna")

    run =
      SpikeFixtures.analyzed_case_set_run(%{
        run_id: run_id,
        condition: "control",
        provider: "openai",
        requested_model: requested_model,
        returned_model: requested_model,
        sample_size: 20
      })

    samples =
      Enum.map(run.samples, fn sample ->
        if sample["case_id"] == "rag_open_synthesis" do
          update_in(sample, ["response", "output_text"], fn output ->
            String.replace(output, "12-knot", "12 knots") <>
              "\n\n#{marker} #{sample["sample_index"]}."
          end)
        else
          sample
        end
      end)

    %{run | samples: samples}
  end

  defp valid_proposed_judgment?(fixture) do
    case fixture["label"] do
      label when label in ~w(meaning_preserving style_only) ->
        fixture["expected_contract_pass"] == true and fixture["failure_modes"] == []

      "subtle_regression" ->
        fixture["expected_contract_pass"] == false and fixture["failure_modes"] != []
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
