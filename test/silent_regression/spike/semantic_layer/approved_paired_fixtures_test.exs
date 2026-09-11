defmodule SilentRegression.Spike.SemanticLayer.ApprovedPairedFixturesTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.SemanticLayer.Storage

  @root "test/fixtures/drift_spike/semantic_layer"
  @expected_sha256 %{
    "tuning-pairs.json" => "0fb83b02e6573ceadb058aa9900b1ab717f888d3f09a25d274c6e72991d712e4",
    "heldout-pairs.json" => "6fdbfef04ee5a23c90223c295406982f39fbb4ccbc4cc912d6d2fc4ce4c7614b"
  }

  test "approved fixture artifacts are frozen, complete copies of the reviewed candidates" do
    for filename <- Map.keys(@expected_sha256) do
      candidate_path = Path.join([@root, "candidates", filename])
      approved_path = Path.join([@root, "approved", filename])

      assert file_sha256(approved_path) == @expected_sha256[filename]
      assert {:ok, candidate} = Storage.read(candidate_path)
      assert {:ok, approved} = Storage.read(approved_path)
      assert candidate.status == "candidate"
      assert approved.status == "approved"
      assert length(candidate.fixtures) == 60
      assert length(approved.fixtures) == 60
      assert comparable(candidate) == comparable(approved)

      assert Enum.all?(approved.fixtures, fn fixture ->
               fixture["approval"]["status"] == "approved" and
                 fixture["approval"]["reviewer"] == "product_owner" and
                 fixture["approval"]["reviewed_at"] == "2026-09-11T03:46:46Z"
             end)
    end
  end

  defp comparable(fixture_set) do
    fixture_set
    |> PairedFixtureSet.to_map()
    |> Map.drop(~w(fixture_set_id created_at git_revision status))
    |> Map.update!("fixtures", fn fixtures ->
      Enum.map(fixtures, &Map.delete(&1, "approval"))
    end)
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
