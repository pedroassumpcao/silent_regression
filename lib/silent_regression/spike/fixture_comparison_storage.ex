defmodule SilentRegression.Spike.FixtureComparisonStorage do
  @moduledoc """
  Atomic persistence for Task 11 fixture-comparison artifacts.

  Existing reports are never overwritten, and reads accept only the validated
  fixture-comparison schema.
  """

  alias SilentRegression.Spike.FixtureComparison

  @spec write(Path.t(), map()) :: :ok | {:error, map()}
  def write(path, report) when is_binary(path) and path != "" and is_map(report) do
    with :ok <- validate(report, path),
         {:ok, encoded} <- encode(report, path),
         :ok <- ensure_new_destination(path),
         :ok <- ensure_parent_directory(path),
         :ok <- write_atomically(path, encoded <> "\n") do
      :ok
    end
  end

  def write(path, _report) do
    {:error, %{type: :invalid_write, path: path, reason: :expected_fixture_comparison}}
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, map()}
  def read(path) when is_binary(path) and path != "" do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode(contents, path),
         :ok <- validate(decoded, path) do
      {:ok, decoded}
    end
  end

  def read(path), do: {:error, %{type: :invalid_read, path: path, reason: :expected_path}}

  defp validate(report, path) do
    case FixtureComparison.validate_report(report) do
      :ok -> :ok
      {:error, cause} -> {:error, %{type: :invalid_artifact, path: path, cause: cause}}
    end
  end

  defp encode(report, path) do
    case Jason.encode(report, pretty: true) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, %{type: :encode_failed, path: path, reason: reason}}
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
    temporary_path = temporary_path(path)

    result =
      with :ok <- write_temporary(temporary_path, path, contents),
           :ok <- rename_temporary(temporary_path, path) do
        :ok
      end

    _ = File.rm(temporary_path)
    result
  end

  defp write_temporary(temporary_path, destination_path, contents) do
    case File.write(temporary_path, contents, [:binary, :exclusive]) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           type: :temporary_write_failed,
           path: destination_path,
           temporary_path: temporary_path,
           reason: reason
         }}
    end
  end

  defp rename_temporary(temporary_path, path) do
    case File.rename(temporary_path, path) do
      :ok -> :ok
      {:error, reason} -> {:error, %{type: :rename_failed, path: path, reason: reason}}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    directory = Path.dirname(path)
    basename = Path.basename(path)
    Path.join(directory, ".#{basename}.tmp-#{suffix}")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, %{type: :read_failed, path: path, reason: reason}}
    end
  end

  defp decode(contents, path) do
    case Jason.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, %{type: :invalid_json, path: path, reason: reason}}
    end
  end
end
