defmodule SilentRegression.CaseExpectationsTest do
  use ExUnit.Case, async: true

  alias SilentRegression.CaseExpectations

  for fixture_file <- ~w(conformance heldout) do
    @fixture_file fixture_file

    test "#{fixture_file} fixtures match their reviewed deterministic outcomes" do
      payload =
        "test/fixtures/case_expectations/v1/#{@fixture_file}.json"
        |> File.read!()
        |> Jason.decode!()

      assert payload["schema_version"] == 1

      Enum.each(payload["fixtures"], fn fixture ->
        assert {:ok, normalized} =
                 CaseExpectations.normalize(
                   CaseExpectations.schema_version(),
                   fixture["expectation"]
                 )

        evaluation =
          CaseExpectations.evaluate(
            normalized.schema_version,
            normalized.expectation,
            normalized.fingerprint,
            fixture["output"]
          )

        assert Atom.to_string(evaluation.status) == fixture["expected_status"], fixture["id"]
        assert Enum.map(evaluation.results, & &1.code) == fixture["expected_codes"], fixture["id"]
      end)
    end
  end

  test "no expectation is explicit, stable, and does not inspect output" do
    assert {:ok, first} = CaseExpectations.normalize(nil, nil)
    assert {:ok, second} = CaseExpectations.normalize("no_case_expectation", %{})
    assert first == second

    evaluation =
      CaseExpectations.evaluate(
        first.schema_version,
        first.expectation,
        first.fingerprint,
        <<255>>
      )

    assert evaluation.status == :not_configured
    assert evaluation.results == []
    assert evaluation.error == nil
  end

  test "required text is an additive case check with strict shape and nonempty literal alternatives" do
    for alternatives <- [[123], [nil], ["!!!"], [], ["x", "X"]] do
      assert {:error, _} =
               CaseExpectations.normalize(nil, %{
                 "checks" => [
                   %{"id" => "answer", "type" => "required_text", "alternatives" => alternatives}
                 ]
               })
    end

    assert {:ok, normalized} =
             CaseExpectations.normalize(nil, %{
               "checks" => [
                 %{
                   "id" => "answer",
                   "type" => "required_text",
                   "alternatives" => ["insufficient evidence", "cannot determine"]
                 }
               ]
             })

    assert normalized.schema_version == "case_expectation_v1"

    for {output, expected} <- [
          {"CANNOT—DETERMINE", :pass},
          {"cannot determineXYZ", :fail},
          {"unsure", :fail}
        ] do
      assert CaseExpectations.evaluate(
               normalized.schema_version,
               normalized.expectation,
               normalized.fingerprint,
               output
             ).status == expected
    end

    assert CaseExpectations.evaluate(
             normalized.schema_version,
             normalized.expectation,
             "stale",
             "cannot determine"
           ).status == :evaluator_error
  end

  test "fingerprint rejects changed expectation content" do
    assert {:ok, normalized} =
             CaseExpectations.normalize("case_expectation_v1", %{
               "checks" => [
                 %{"id" => "route", "type" => "label", "allowed_values" => ["billing"]}
               ]
             })

    changed =
      put_in(normalized.expectation, ["checks", Access.at(0), "allowed_values"], ["sales"])

    evaluation =
      CaseExpectations.evaluate(
        normalized.schema_version,
        changed,
        normalized.fingerprint,
        "sales"
      )

    assert evaluation.status == :evaluator_error
    assert evaluation.error["code"] == "expectation_fingerprint_mismatch"
  end

  test "rejects unsupported fields, duplicate IDs, unsafe pointers, and invalid source sets" do
    invalid_expectations = [
      %{
        "checks" => [
          %{"id" => "route", "type" => "label", "allowed_values" => ["a"], "extra" => true}
        ]
      },
      %{
        "checks" => [
          %{"id" => "same", "type" => "label", "allowed_values" => ["a"]},
          %{"id" => "same", "type" => "label", "allowed_values" => ["b"]}
        ]
      },
      %{
        "checks" => [
          %{
            "id" => "value",
            "type" => "json_value",
            "path" => "missing-slash",
            "allowed_values" => [1],
            "numeric_comparison" => "strict"
          }
        ]
      },
      %{
        "checks" => [
          %{
            "id" => "sources",
            "type" => "source_ids",
            "required" => ["doc-2"],
            "allowed" => ["doc-1"],
            "require_at_least_one" => true
          }
        ]
      }
    ]

    Enum.each(invalid_expectations, fn expectation ->
      assert {:error, _error} =
               CaseExpectations.normalize(CaseExpectations.schema_version(), expectation)
    end)
  end
end
