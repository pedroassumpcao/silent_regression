defmodule SilentRegression.Spike.CandidateFixturesTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.DeterministicChecks
  alias SilentRegression.Spike.Run

  @fixture_root Path.expand("../../fixtures/drift_spike/candidates", __DIR__)
  @manifest_path Path.join(@fixture_root, "manifest.json")

  test "manifest inventories every candidate fixture file and ID" do
    manifest = read_json!(@manifest_path)

    assert manifest["schema_version"] == 1
    assert manifest["status"] == "candidate"
    assert manifest["review_required"] == true
    assert manifest["sample_size"] == 20

    declared_files = Enum.map(manifest["fixture_files"], & &1["file"])

    actual_files =
      @fixture_root
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.reject(&(&1 == "manifest.json"))

    assert Enum.sort(declared_files) == Enum.sort(actual_files)
    assert MapSet.size(MapSet.new(declared_files)) == length(declared_files)

    fixture_ids =
      Enum.flat_map(manifest["fixture_files"], fn entry ->
        document = read_json!(Path.join(@fixture_root, entry["file"]))
        actual_ids = Enum.map(document["fixtures"], & &1["id"])

        assert document["case_id"] == entry["case_id"]
        assert actual_ids == entry["expected_fixture_ids"]
        actual_ids
      end)

    assert MapSet.size(MapSet.new(fixture_ids)) == length(fixture_ids)
  end

  test "candidate files match the frozen cases and declared deterministic outcomes" do
    manifest = read_json!(@manifest_path)
    cases_by_id = Map.new(CaseSet.all(), &{&1.id, &1})

    fixtures =
      Enum.flat_map(manifest["fixture_files"], fn entry ->
        document = read_json!(Path.join(@fixture_root, entry["file"]))
        case_definition = Map.fetch!(cases_by_id, document["case_id"])

        assert document["schema_version"] == 1
        assert document["status"] == "candidate"
        assert document["case_version"] == case_definition.version
        assert document["case_fingerprint"] == case_definition.fingerprint

        Enum.map(document["fixtures"], fn fixture ->
          assert valid_fixture_shape?(fixture), "invalid candidate shape: #{inspect(fixture)}"

          assert {:ok, result} =
                   DeterministicChecks.evaluate(case_definition, fixture["output_text"])

          assert result["all_passed"] == fixture["expected_deterministic_pass"],
                 "#{fixture["id"]} deterministic expectation did not match"

          Map.put(fixture, "case_id", document["case_id"])
        end)
      end)

    required_failure_modes = MapSet.new(manifest["required_failure_modes"])

    actual_failure_modes =
      fixtures
      |> Enum.flat_map(& &1["failure_modes"])
      |> MapSet.new()

    assert MapSet.subset?(required_failure_modes, actual_failure_modes)
    assert Enum.any?(fixtures, &semantic_only_regression?/1)
  end

  test "batch blueprints are complete, reproducible, and use only matching fixtures" do
    manifest = read_json!(@manifest_path)
    fixtures = load_fixtures(manifest)
    fixtures_by_id = Map.new(fixtures, &{&1["id"], &1})
    case_ids = CaseSet.all() |> Enum.map(& &1.id) |> MapSet.new()
    batches = manifest["batch_blueprints"]

    batch_ids = Enum.map(batches, & &1["id"])
    assert MapSet.size(MapSet.new(batch_ids)) == length(batch_ids)

    selected_fixture_ids =
      Enum.reduce(batches, MapSet.new(), fn batch, selected_fixture_ids ->
        assert batch["condition"] in Run.conditions()
        assert batch["intended_label"] in ["acceptable", "regression"]
        assert batch["sample_size"] == manifest["sample_size"]
        assert non_empty_string?(batch["rationale"])

        applies_to = MapSet.new(batch["applies_to_case_ids"])
        assert MapSet.equal?(applies_to, case_ids)

        validate_assembly!(batch, fixtures)

        matching_fixtures =
          Enum.filter(fixtures, fn fixture ->
            fixture_matches?(fixture, batch["assembly"]["fixture_filter"])
          end)

        Enum.each(batch["applies_to_case_ids"], fn case_id ->
          case_matches = Enum.filter(matching_fixtures, &(&1["case_id"] == case_id))
          assert case_matches != [], "#{batch["id"]} has no fixtures for #{case_id}"
          assert Enum.all?(case_matches, &(&1["intended_label"] == batch["intended_label"]))
        end)

        Enum.reduce(matching_fixtures, selected_fixture_ids, fn fixture, selected ->
          assert Map.has_key?(fixtures_by_id, fixture["id"])
          MapSet.put(selected, fixture["id"])
        end)
      end)

    assert MapSet.equal?(selected_fixture_ids, MapSet.new(Map.keys(fixtures_by_id)))
  end

  defp validate_assembly!(batch, fixtures) do
    assembly = batch["assembly"]
    sample_size = batch["sample_size"]

    case assembly["type"] do
      "cycle_matching_fixtures" ->
        assert batch["expected_regression_rate"] in [0.0, 1.0]

      "replace_control_samples" ->
        indexes = assembly["sample_indexes"]

        assert assembly["base_condition"] == "control"
        assert is_list(indexes) and indexes != []
        assert Enum.uniq(indexes) == indexes
        assert Enum.all?(indexes, &(is_integer(&1) and &1 >= 0 and &1 < sample_size))

        assert_in_delta batch["expected_regression_rate"], length(indexes) / sample_size, 1.0e-12

      type ->
        flunk("unsupported candidate batch assembly: #{inspect(type)}")
    end

    filter = assembly["fixture_filter"]
    assert is_map(filter) and map_size(filter) > 0
    assert Enum.any?(fixtures, &fixture_matches?(&1, filter))
  end

  defp valid_fixture_shape?(fixture) do
    non_empty_string?(fixture["id"]) and
      fixture["condition"] in ["harmless_rewording", "subtle_regression", "obvious_regression"] and
      fixture["variant_type"] in [
        "meaning_preserving",
        "style_only",
        "wrong_fact",
        "wrong_attribution",
        "unsupported_claim",
        "omission",
        "failed_abstention",
        "multiple_wrong_facts"
      ] and
      fixture["intended_label"] in ["acceptable", "regression"] and
      fixture["severity"] in ["none", "subtle", "obvious"] and
      is_list(fixture["failure_modes"]) and
      is_boolean(fixture["expected_deterministic_pass"]) and
      non_empty_string?(fixture["rationale"]) and
      non_empty_string?(fixture["output_text"])
  end

  defp semantic_only_regression?(fixture) do
    fixture["intended_label"] == "regression" and fixture["expected_deterministic_pass"] == true
  end

  defp fixture_matches?(fixture, filter) do
    Enum.all?(filter, fn {key, value} -> fixture[key] == value end)
  end

  defp load_fixtures(manifest) do
    Enum.flat_map(manifest["fixture_files"], fn entry ->
      document = read_json!(Path.join(@fixture_root, entry["file"]))
      Enum.map(document["fixtures"], &Map.put(&1, "case_id", document["case_id"]))
    end)
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
