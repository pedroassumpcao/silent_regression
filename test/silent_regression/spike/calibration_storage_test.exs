defmodule SilentRegression.Spike.CalibrationStorageTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.Calibrator
  alias SilentRegression.SpikeFixtures

  @tag :tmp_dir
  test "atomically writes, reads, and refuses to overwrite a calibration", %{tmp_dir: tmp_dir} do
    baseline =
      SpikeFixtures.analyzed_run(%{
        run_id: "baseline",
        outputs: ["red apple", "red fruit", "apple fruit", "red berry"]
      })

    control =
      SpikeFixtures.analyzed_run(%{
        run_id: "control",
        condition: "control",
        outputs: ["apple red", "fruit red", "fruit apple", "berry red"]
      })

    assert {:ok, calibration} =
             Calibrator.build(baseline, [control],
               seed: 8,
               iterations: 20,
               calibration_id: "calibration",
               clock: fn -> ~U[2026-09-07 13:00:00Z] end,
               git_revision: nil
             )

    path = Path.join([tmp_dir, "nested", "calibration.json"])
    assert :ok = CalibrationStorage.write(path, calibration)
    assert {:ok, ^calibration} = CalibrationStorage.read(path)
    assert File.read!(path) |> String.ends_with?("\n")

    assert {:error, %{type: :already_exists, path: ^path}} =
             CalibrationStorage.write(path, calibration)

    assert File.ls!(Path.dirname(path)) == ["calibration.json"]
  end

  @tag :tmp_dir
  test "returns structured errors for malformed and future artifacts", %{tmp_dir: tmp_dir} do
    malformed = Path.join(tmp_dir, "malformed.json")
    File.write!(malformed, "{invalid")
    assert {:error, %{type: :invalid_json, path: ^malformed}} = CalibrationStorage.read(malformed)

    future = Path.join(tmp_dir, "future.json")
    File.write!(future, Jason.encode!(%{"schema_version" => 99}))

    assert {:error, %{type: :unsupported_schema_version, path: ^future, expected: 1, actual: 99}} =
             CalibrationStorage.read(future)
  end
end
