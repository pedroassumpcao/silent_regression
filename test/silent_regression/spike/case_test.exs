defmodule SilentRegression.Spike.CaseTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Case
  alias SilentRegression.SpikeFixtures

  describe "new/1" do
    test "builds a case from atom or string keyed attributes" do
      attributes =
        SpikeFixtures.case_definition()
        |> Case.to_map()
        |> Map.put(:description, "An updated description")
        |> Map.delete("description")

      assert {:ok, case_definition} = Case.new(attributes)
      assert case_definition.description == "An updated description"
      assert case_definition.checks == [%{"type" => "required_phrase", "value" => "Tuesday"}]
    end

    test "reports a structured error for a missing required field" do
      attributes = SpikeFixtures.case_definition() |> Case.to_map() |> Map.delete("id")

      assert {:error,
              %{
                type: :validation_error,
                source: Case,
                field: :id,
                reason: :required
              }} = Case.new(attributes)
    end

    test "rejects non-JSON check specifications" do
      attributes =
        SpikeFixtures.case_definition()
        |> Case.to_map()
        |> Map.put("checks", [%{"matcher" => {:not, :json}}])

      assert {:error, %{field: :checks, reason: :must_be_a_list_of_json_objects}} =
               Case.new(attributes)
    end

    test "rejects malformed fingerprints" do
      attributes =
        SpikeFixtures.case_definition()
        |> Case.to_map()
        |> Map.put("fingerprint", "not-a-digest")

      assert {:error, %{field: :fingerprint, reason: :must_be_a_sha256_hex_digest}} =
               Case.new(attributes)
    end
  end

  test "the persisted representation round-trips explicitly" do
    original = SpikeFixtures.case_definition()

    assert {:ok, decoded} = original |> Case.to_map() |> Case.from_map()
    assert decoded == original
    assert Case.to_map(original) |> Map.keys() |> Enum.all?(&is_binary/1)
  end
end
