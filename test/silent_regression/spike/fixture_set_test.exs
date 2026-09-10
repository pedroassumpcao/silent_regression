defmodule SilentRegression.Spike.FixtureSetTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.FixtureSet

  test "loads only the committed approved fixture set" do
    assert {:ok, fixture_set} = FixtureSet.load()

    assert fixture_set["root"] == FixtureSet.official_root()
    assert fixture_set["manifest"]["status"] == "approved"
    assert length(fixture_set["fixtures"]) == 28
    assert map_size(fixture_set["fixtures_by_case"]) == 4
    assert map_size(fixture_set["file_sha256s"]) == 4
    assert fixture_set["manifest_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

    assert Enum.all?(fixture_set["file_sha256s"], fn {_file, digest} ->
             digest =~ ~r/\A[0-9a-f]{64}\z/
           end)
  end

  test "refuses candidate and arbitrary fixture paths for official reports" do
    candidate_root =
      FixtureSet.official_root()
      |> Path.dirname()
      |> Path.join("candidates")

    for path <- [candidate_root, System.tmp_dir!()] do
      assert {:error, error} = FixtureSet.load(path)
      assert error["type"] == "unapproved_fixture_path"
      assert error["details"]["expected"] == FixtureSet.official_root()
    end
  end
end
