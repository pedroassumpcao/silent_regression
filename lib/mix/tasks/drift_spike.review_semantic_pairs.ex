defmodule Mix.Tasks.DriftSpike.ReviewSemanticPairs do
  @shortdoc "Prints a traceable page of semantic fixture candidates for review"

  @moduledoc """
  Prints a read-only Markdown review page for one candidate fixture set and its
  exact source control.

      mix drift_spike.review_semantic_pairs --fixtures PAIRS.json --source CONTROL.json --from 1 --count 5

  Parent numbering is one-based. The default page is parents 1-5. This task
  makes zero provider calls and never changes or approves an artifact.
  """

  use Mix.Task

  alias SilentRegression.Spike.SemanticLayer.PairedFixtureReview
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Storage

  @switches [fixtures: :string, source: :string, from: :integer, count: :integer, help: :boolean]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")

    case OptionParser.parse(arguments, strict: @switches) do
      {options, remaining, invalid} ->
        cond do
          Keyword.get(options, :help, false) ->
            Mix.shell().info(@moduledoc)

          remaining != [] or invalid != [] ->
            Mix.raise("Invalid semantic-review arguments: #{inspect(remaining ++ invalid)}")

          true ->
            review(options)
        end
    end
  end

  defp review(options) do
    fixture_path = required_string!(options, :fixtures)
    source_path = required_string!(options, :source)
    fixture_set = read_fixture_set!(fixture_path)
    source_run = read_source!(source_path)
    verify_source_hash!(fixture_set.source_control["artifact_sha256"], source_path)

    case PairedFixtureReview.render(fixture_set, source_run,
           from: Keyword.get(options, :from, 1),
           count: Keyword.get(options, :count, 5)
         ) do
      {:ok, markdown} ->
        Mix.shell().info(markdown)
        Mix.shell().info("Provider calls: 0")
        Mix.shell().info("Artifacts changed: 0")

      {:error, error} ->
        Mix.raise(format_error(error, "Could not render semantic review"))
    end
  end

  defp read_fixture_set!(path) do
    case SemanticStorage.read(path) do
      {:ok, fixture_set} -> fixture_set
      {:error, error} -> Mix.raise(format_error(error, "Could not read paired fixture set"))
    end
  end

  defp read_source!(path) do
    case Storage.read(path) do
      {:ok, source_run} -> source_run
      {:error, error} -> Mix.raise(format_error(error, "Could not read source control"))
    end
  end

  defp verify_source_hash!(expected, path) do
    actual = file_sha256!(path)

    if actual == expected,
      do: :ok,
      else: Mix.raise("Source control SHA-256 does not match the fixture provenance")
  end

  defp required_string!(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      {:ok, _value} -> Mix.raise("--#{name} must be a non-empty string")
      :error -> Mix.raise("--#{name} is required")
    end
  end

  defp file_sha256!(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:error, reason} -> Mix.raise("Could not hash #{path}: #{inspect(reason)}")
    end
  end

  defp format_error(error, fallback) when is_map(error) do
    type = Map.get(error, "type", Map.get(error, :type, "unknown_error"))
    message = Map.get(error, "message", Map.get(error, :message, fallback))
    details = Map.get(error, "details", Map.get(error, :details, error))
    "#{message} (#{type}): #{inspect(details)}"
  end

  defp format_error(error, fallback), do: "#{fallback}: #{inspect(error)}"
end
