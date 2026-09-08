defmodule SilentRegression.Spike.CalibrationTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Calibration

  test "round-trips a complete calibration artifact" do
    original = calibration()

    assert {:ok, decoded} = original |> Calibration.to_map() |> Calibration.from_map()
    assert decoded == original
    assert Calibration.to_map(original) |> Map.keys() |> Enum.all?(&is_binary/1)
  end

  test "rejects unsupported schema versions and inconsistent source IDs" do
    unsupported = calibration() |> Calibration.to_map() |> Map.put("schema_version", 99)

    assert {:error, %{type: :unsupported_schema_version, expected: 1, actual: 99}} =
             Calibration.from_map(unsupported)

    inconsistent =
      calibration()
      |> Calibration.to_map()
      |> Map.put("source_run_ids", ["control"])

    assert {:error, %{field: :source_run_ids}} = Calibration.from_map(inconsistent)
  end

  test "requires thresholds to match provenance case order" do
    invalid =
      calibration()
      |> Calibration.to_map()
      |> put_in(["thresholds", Access.at(0), "case_id"], "different")

    assert {:error, %{field: :thresholds, reason: :must_match_provenance_cases}} =
             Calibration.from_map(invalid)
  end

  defp calibration do
    {:ok, calibration} =
      Calibration.new(%{
        calibration_id: "calibration-1",
        created_at: ~U[2026-09-07 13:00:00Z],
        git_revision: "abc123",
        baseline_run_id: "baseline",
        control_run_ids: ["control"],
        source_run_ids: ["baseline", "control"],
        provenance: %{
          "provider" => "fake",
          "request_config" => %{"model" => "fake-model"},
          "returned_models" => ["fake-model"],
          "cases" => [
            %{
              "id" => "rag_case",
              "version" => 1,
              "fingerprint" => String.duplicate("a", 64)
            }
          ]
        },
        settings: %{
          "seed" => 1,
          "iterations" => 20,
          "quantile" => 0.95,
          "adjusted_p_alpha" => 0.05,
          "baseline_group_size" => 2,
          "control_group_size" => 2
        },
        thresholds: [
          %{
            "case_id" => "rag_case",
            "case_fingerprint" => String.duplicate("a", 64),
            "threshold" => 0.2,
            "null_energies" => [0.0, 0.2]
          }
        ]
      })

    calibration
  end
end
