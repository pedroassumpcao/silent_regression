defmodule SilentRegression.Spike.ResponseTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Response
  alias SilentRegression.SpikeFixtures

  describe "new/1" do
    test "normalizes atom-keyed usage without losing zero token counts" do
      attributes =
        SpikeFixtures.response()
        |> Map.from_struct()
        |> Map.put(:usage, %{input_tokens: 0, output_tokens: 0})

      assert {:ok, response} = Response.new(attributes)
      assert response.usage == %{"input_tokens" => 0, "output_tokens" => 0}
    end

    test "allows an empty provider output for downstream failure scoring" do
      attributes = SpikeFixtures.response() |> Map.from_struct() |> Map.put(:output_text, "")

      assert {:ok, response} = Response.new(attributes)
      assert response.output_text == ""
    end

    test "rejects invalid token usage" do
      attributes =
        SpikeFixtures.response()
        |> Map.from_struct()
        |> Map.put(:usage, %{"input_tokens" => 1, "output_tokens" => -1})

      assert {:error, %{field: :output_tokens, reason: :must_be_a_non_negative_integer}} =
               Response.new(attributes)
    end

    test "rejects raw responses that cannot be persisted as JSON" do
      attributes =
        SpikeFixtures.response()
        |> Map.from_struct()
        |> Map.put(:raw, %{"received_at" => ~U[2026-09-07 12:00:00Z]})

      assert {:error, %{field: :raw, reason: :must_be_a_json_object_with_string_keys}} =
               Response.new(attributes)
    end

    test "rejects malformed capture timestamps" do
      attributes =
        SpikeFixtures.response()
        |> Response.to_map()
        |> Map.put("captured_at", "yesterday")

      assert {:error, %{field: :captured_at, reason: :must_be_an_iso8601_datetime}} =
               Response.from_map(attributes)
    end
  end

  test "the persisted representation round-trips timestamps and provider metadata" do
    original = SpikeFixtures.response()

    assert {:ok, decoded} = original |> Response.to_map() |> Response.from_map()
    assert decoded == original
    assert Response.to_map(original) |> Map.keys() |> Enum.all?(&is_binary/1)
  end
end
