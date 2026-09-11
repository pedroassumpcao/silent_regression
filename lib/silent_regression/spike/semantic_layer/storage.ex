defmodule SilentRegression.Spike.SemanticLayer.Storage do
  @moduledoc """
  Atomic, no-overwrite persistence for semantic-layer experiment artifacts.

  Dispatch is based on a closed artifact-type registry. Earlier spike artifacts
  are deliberately unsupported so this experiment cannot rewrite or reinterpret
  the frozen Task 11 evidence through this storage boundary.
  """

  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.Calibration
  alias SilentRegression.Spike.SemanticLayer.ContractRescoreResult
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.SemanticLayer.RepresentationSpec

  @modules [
    PairedFixtureSet,
    RepresentationSpec,
    Calibration,
    BenchmarkResult,
    ContractRescoreResult
  ]
  @modules_by_type Map.new(@modules, &{&1.artifact_type(), &1})

  @spec write(Path.t(), struct()) :: :ok | {:error, map()}
  def write(path, artifact) when is_binary(path) and path != "" and is_struct(artifact) do
    with {:ok, module} <- module_for_struct(artifact),
         :ok <- validate(module, artifact, path),
         {:ok, encoded} <- encode(module, artifact, path),
         :ok <- ensure_new_destination(path),
         :ok <- ensure_parent_directory(path),
         :ok <- write_atomically(path, encoded <> "\n") do
      :ok
    end
  end

  def write(path, _artifact) do
    {:error, %{type: :invalid_write, path: path, reason: :expected_semantic_layer_artifact}}
  end

  @spec read(Path.t()) :: {:ok, struct()} | {:error, map()}
  def read(path) when is_binary(path) and path != "" do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode(contents, path),
         {:ok, module} <- module_for_type(decoded["artifact_type"], path),
         {:ok, artifact} <- build(module, decoded, path) do
      {:ok, artifact}
    end
  end

  def read(path), do: {:error, %{type: :invalid_read, path: path, reason: :expected_path}}

  defp module_for_struct(artifact) do
    module = artifact.__struct__

    if module in @modules,
      do: {:ok, module},
      else: {:error, %{type: :unsupported_artifact, module: module}}
  end

  defp module_for_type(type, path) do
    case Map.fetch(@modules_by_type, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, %{type: :unsupported_artifact_type, path: path, artifact_type: type}}
    end
  end

  defp validate(module, artifact, path) do
    case module.validate(artifact) do
      :ok -> :ok
      {:error, cause} -> {:error, %{type: :invalid_artifact, path: path, cause: cause}}
    end
  end

  defp encode(module, artifact, path) do
    case Jason.encode(module.to_map(artifact), pretty: true) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, %{type: :encode_failed, path: path, reason: reason}}
    end
  end

  defp build(module, decoded, path) do
    case module.from_map(decoded) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, cause} -> {:error, %{type: :invalid_artifact, path: path, cause: cause}}
    end
  end

  defp ensure_new_destination(path) do
    if File.exists?(path),
      do: {:error, %{type: :already_exists, path: path}},
      else: :ok
  end

  defp ensure_parent_directory(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, %{type: :mkdir_failed, path: path, reason: reason}}
    end
  end

  defp write_atomically(path, contents) do
    suffix = System.unique_integer([:positive, :monotonic])
    temporary_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")

    result =
      with :ok <- File.write(temporary_path, contents, [:binary, :exclusive]),
           :ok <- File.rename(temporary_path, path) do
        :ok
      end

    _ = File.rm(temporary_path)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, %{type: :write_failed, path: path, reason: reason}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, %{type: :read_failed, path: path, reason: reason}}
    end
  end

  defp decode(contents, path) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, %{type: :invalid_json_object, path: path}}
      {:error, reason} -> {:error, %{type: :invalid_json, path: path, reason: reason}}
    end
  end
end
