defmodule SilentRegression.Spike.SemanticLayer.PairedFixtureReviewTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.{PairedFixtureDraft, PairedFixtureReview}
  alias SilentRegression.SpikeFixtures

  test "renders a bounded parent-and-candidate page with exact source provenance" do
    source = distinct_control("review-control")
    {:ok, fixture_set} = PairedFixtureDraft.build(source, hash("source"), "tuning")

    assert {:ok, markdown} = PairedFixtureReview.render(fixture_set, source, from: 2, count: 2)
    assert markdown =~ "# Semantic fixture review: tuning"
    assert markdown =~ "Review page: parents 2-3 of 20"
    assert markdown =~ "## Parent 2 of 20 — source sample 1"
    assert markdown =~ "## Parent 3 of 20 — source sample 2"
    assert markdown =~ "### meaning_preserving — proposed: valid"
    assert markdown =~ "### style_only — proposed: valid"
    assert markdown =~ "### subtle_regression — proposed: regression"
    refute markdown =~ "source sample 0\n"
  end

  test "rejects stale parent hashes and invalid page bounds" do
    source = distinct_control("review-control")
    {:ok, fixture_set} = PairedFixtureDraft.build(source, hash("source"), "heldout")

    stale_fixtures =
      Enum.map(fixture_set.fixtures, fn fixture ->
        if fixture["parent_sample_index"] == 0,
          do: Map.put(fixture, "parent_output_sha256", String.duplicate("0", 64)),
          else: fixture
      end)

    assert {:error, %{"type" => "source_mismatch", "message" => message}} =
             PairedFixtureReview.render(%{fixture_set | fixtures: stale_fixtures}, source)

    assert message =~ "hash"

    assert {:error, %{"type" => "configuration_error"}} =
             PairedFixtureReview.render(fixture_set, source, from: 21)

    assert {:error, %{"type" => "configuration_error"}} =
             PairedFixtureReview.render(fixture_set, source, [1])
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

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
