defmodule SilentRegression.Spike.RunTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Run
  alias SilentRegression.SpikeFixtures

  test "a complete artifact round-trips with case snapshots" do
    original = SpikeFixtures.run()

    assert {:ok, decoded} = original |> Run.to_map() |> Run.from_map()
    assert decoded == original
    assert [%Case{id: "rag_case"}] = decoded.cases
    assert Run.to_map(original) |> Map.keys() |> Enum.all?(&is_binary/1)
  end

  test "rejects unsupported artifact schema versions" do
    attributes = SpikeFixtures.run() |> Run.to_map() |> Map.put("schema_version", 2)

    assert {:error,
            %{
              type: :unsupported_schema_version,
              source: Run,
              expected: 1,
              actual: 2
            }} = Run.from_map(attributes)
  end

  test "reports missing required artifact fields" do
    attributes = SpikeFixtures.run() |> Run.to_map() |> Map.delete("provider")

    assert {:error, %{field: :provider, reason: :required}} = Run.from_map(attributes)
  end

  test "identifies the index and cause of an invalid case snapshot" do
    invalid_case = SpikeFixtures.case_definition() |> Case.to_map() |> Map.delete("question")
    attributes = SpikeFixtures.run() |> Run.to_map() |> Map.put("cases", [invalid_case])

    assert {:error,
            %{
              type: :invalid_case,
              field: :cases,
              index: 0,
              cause: %{field: :question, reason: :required}
            }} = Run.from_map(attributes)
  end

  test "rejects a completion timestamp before the start" do
    attributes =
      SpikeFixtures.run()
      |> Map.from_struct()
      |> Map.put(:completed_at, ~U[2026-09-07 11:59:59Z])

    assert {:error, %{field: :completed_at, reason: :must_not_precede_started_at}} =
             Run.new(attributes)
  end

  test "rejects unrecognized conditions" do
    attributes = SpikeFixtures.run() |> Map.from_struct() |> Map.put(:condition, "surprise")

    assert {:error, %{field: :condition, reason: :unsupported_condition}} = Run.new(attributes)
  end
end
