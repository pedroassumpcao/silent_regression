defmodule SilentRegression.Spike.StorageTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFixtures

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "silent-regression-storage-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "atomically writes and reads a run from a new nested directory", %{root: root} do
    path = Path.join([root, "nested", "run.json"])
    run = SpikeFixtures.run()

    assert :ok = Storage.write(path, run)
    assert {:ok, ^run} = Storage.read(path)
    assert File.read!(path) |> String.ends_with?("\n")
    assert ["run.json"] = path |> Path.dirname() |> File.ls!()
  end

  test "refuses to overwrite an existing artifact", %{root: root} do
    path = Path.join(root, "run.json")
    File.mkdir_p!(root)
    File.write!(path, "keep me")

    assert {:error, %{type: :already_exists, path: ^path}} =
             Storage.write(path, SpikeFixtures.run())

    assert File.read!(path) == "keep me"
  end

  test "does not create a file for an invalid run", %{root: root} do
    path = Path.join(root, "invalid.json")
    invalid_run = %{SpikeFixtures.run() | label: ""}

    assert {:error,
            %{
              type: :invalid_artifact,
              path: ^path,
              cause: %{field: :label, reason: :must_be_a_non_empty_string}
            }} = Storage.write(path, invalid_run)

    refute File.exists?(path)
  end

  test "returns a structured error for malformed JSON", %{root: root} do
    path = write_raw_artifact(root, "malformed.json", "{not-json")

    assert {:error, %{type: :invalid_json, path: ^path}} = Storage.read(path)
  end

  test "returns the unsupported schema version without hiding it", %{root: root} do
    artifact = SpikeFixtures.run() |> Run.to_map() |> Map.put("schema_version", 99)
    path = write_raw_artifact(root, "future.json", Jason.encode!(artifact))

    assert {:error,
            %{
              type: :unsupported_schema_version,
              path: ^path,
              expected: 1,
              actual: 99
            }} = Storage.read(path)
  end

  test "wraps structurally invalid JSON as an invalid artifact", %{root: root} do
    artifact = SpikeFixtures.run() |> Run.to_map() |> Map.delete("run_id")
    path = write_raw_artifact(root, "invalid.json", Jason.encode!(artifact))

    assert {:error,
            %{
              type: :invalid_artifact,
              path: ^path,
              cause: %{field: :run_id, reason: :required}
            }} = Storage.read(path)
  end

  test "returns a structured read error for a missing artifact", %{root: root} do
    path = Path.join(root, "missing.json")

    assert {:error, %{type: :read_failed, path: ^path, reason: :enoent}} = Storage.read(path)
  end

  defp write_raw_artifact(root, filename, contents) do
    File.mkdir_p!(root)
    path = Path.join(root, filename)
    File.write!(path, contents)
    path
  end
end
