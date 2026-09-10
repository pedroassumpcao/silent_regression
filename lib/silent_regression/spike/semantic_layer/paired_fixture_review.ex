defmodule SilentRegression.Spike.SemanticLayer.PairedFixtureReview do
  @moduledoc """
  Renders traceable parent-and-derivative pages for human semantic review.

  Rendering is read-only. Before showing any text, the module proves that each
  fixture points to the exact source observation identified by its run, case,
  sample index, and output hash.
  """

  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet

  @labels ~w(meaning_preserving style_only subtle_regression)

  @spec render(PairedFixtureSet.t(), Run.t(), keyword()) ::
          {:ok, String.t()} | {:error, map()}
  def render(fixture_set, source_run, options \\ [])

  def render(%PairedFixtureSet{} = fixture_set, %Run{} = source_run, options)
      when is_list(options) do
    with :ok <- validate_options(options) do
      render_validated(fixture_set, source_run, options)
    end
  end

  def render(_fixture_set, _source_run, _options),
    do: error(:configuration_error, "Review requires a paired fixture set and source run")

  defp render_validated(fixture_set, source_run, options) do
    from = Keyword.get(options, :from, 1)
    count = Keyword.get(options, :count, 5)

    with :ok <- PairedFixtureSet.validate(fixture_set),
         :ok <- validate_source(fixture_set, source_run),
         {:ok, parents} <- parents(fixture_set, source_run),
         :ok <- validate_page(from, count, length(parents)) do
      selected = Enum.slice(parents, from - 1, count)
      {:ok, render_page(fixture_set, selected, from, length(parents))}
    end
  end

  defp validate_options(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)

      cond do
        Enum.uniq(keys) != keys ->
          error(:configuration_error, "Review options must be unique")

        keys -- [:from, :count] != [] ->
          error(:configuration_error, "Review options contain unsupported keys")

        true ->
          :ok
      end
    else
      error(:configuration_error, "Review options must be a keyword list")
    end
  end

  defp validate_source(fixture_set, source_run) do
    source = fixture_set.source_control

    cond do
      source["run_id"] != source_run.run_id ->
        error(:source_mismatch, "Fixture set and source run IDs do not match")

      source["condition"] != source_run.condition ->
        error(:source_mismatch, "Fixture set and source conditions do not match")

      source_run.condition != "control" ->
        error(:source_mismatch, "Fixture review requires a control source")

      true ->
        :ok
    end
  end

  defp parents(fixture_set, source_run) do
    case_id = fixture_set.source_control["case_id"]

    source_samples =
      source_run.samples
      |> Enum.filter(&(&1["case_id"] == case_id))
      |> Map.new(&{&1["sample_index"], &1})

    fixture_set.fixtures
    |> Enum.group_by(& &1["parent_sample_index"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {sample_index, fixtures}, {:ok, acc} ->
      case validate_parent(fixtures, source_samples[sample_index], source_run.run_id, case_id) do
        {:ok, parent} -> {:cont, {:ok, [parent | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, parents} -> {:ok, Enum.reverse(parents)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_parent(fixtures, source_sample, run_id, case_id) when is_map(source_sample) do
    sample_index = source_sample["sample_index"]
    output = get_in(source_sample, ["response", "output_text"])
    parent_id = "#{run_id}:#{case_id}:#{sample_index}"
    fixtures_by_label = Map.new(fixtures, &{&1["label"], &1})

    if is_binary(output) do
      parent_hash = sha256(output)

      cond do
        Enum.sort(Map.keys(fixtures_by_label)) != Enum.sort(@labels) ->
          error(:fixture_mismatch, "Parent does not have exactly the review labels", %{
            "sample_index" => sample_index
          })

        not Enum.all?(fixtures, &(&1["parent_observation_id"] == parent_id)) ->
          error(:source_mismatch, "Parent observation ID does not match its source", %{
            "sample_index" => sample_index
          })

        not Enum.all?(fixtures, &(&1["parent_output_sha256"] == parent_hash)) ->
          error(:source_mismatch, "Parent output hash does not match its source", %{
            "sample_index" => sample_index
          })

        true ->
          {:ok,
           %{
             sample_index: sample_index,
             parent_id: parent_id,
             output: output,
             fixtures: Enum.map(@labels, &Map.fetch!(fixtures_by_label, &1))
           }}
      end
    else
      error(:source_mismatch, "Parent source output is missing", %{
        "sample_index" => sample_index
      })
    end
  end

  defp validate_parent(_fixtures, _source_sample, _run_id, _case_id),
    do: error(:source_mismatch, "A fixture parent is absent from the source run")

  defp validate_page(from, count, total)
       when is_integer(from) and is_integer(count) and from >= 1 and count >= 1 and from <= total,
       do: :ok

  defp validate_page(from, count, total) do
    error(:configuration_error, "Review page is outside the available parent range", %{
      "from" => from,
      "count" => count,
      "total_parents" => total
    })
  end

  defp render_page(fixture_set, parents, from, total) do
    split = parents |> hd() |> Map.fetch!(:fixtures) |> hd() |> Map.fetch!("split")
    last = min(from + length(parents) - 1, total)

    header = """
    # Semantic fixture review: #{split}

    Fixture set: #{fixture_set.fixture_set_id}
    Source control: #{fixture_set.source_control["run_id"]}
    Status: #{fixture_set.status}
    Review page: parents #{from}-#{last} of #{total}

    Judge each candidate against the original and the supplied case facts. Approve a label only when the proposed expectation, failure modes, and rationale are accurate. Presentation differences alone are valid. For the held-out partition, record judgments but do not change the evaluator, representation, weights, thresholds, or seeds in response.
    """

    body =
      parents
      |> Enum.with_index(from)
      |> Enum.map_join("\n", fn {parent, ordinal} -> render_parent(parent, ordinal, total) end)

    footer = """

    ## Decision format

    Approve all three candidates for a parent, or list the fixture ID and the required correction. No approval is written by this review command.
    """

    String.trim(header <> "\n" <> body <> footer) <> "\n"
  end

  defp render_parent(parent, ordinal, total) do
    candidates = Enum.map_join(parent.fixtures, "\n", &render_candidate/1)

    """
    ## Parent #{ordinal} of #{total} — source sample #{parent.sample_index}

    Parent observation: #{parent.parent_id}

    ### Original control output

    #{blockquote(parent.output)}

    #{candidates}
    """
  end

  defp render_candidate(fixture) do
    expected = if fixture["expected_contract_pass"], do: "valid", else: "regression"

    failure_modes =
      if fixture["failure_modes"] == [],
        do: "none",
        else: Enum.join(fixture["failure_modes"], ", ")

    """
    ### #{fixture["label"]} — proposed: #{expected}

    Fixture ID: #{fixture["fixture_id"]}
    Failure modes: #{failure_modes}
    Rationale: #{fixture["rationale"]}

    #{blockquote(fixture["output_text"])}
    """
  end

  defp blockquote(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &if(&1 == "", do: ">", else: "> " <> &1))
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp error(type, message, details \\ %{}) do
    {:error, %{"type" => Atom.to_string(type), "message" => message, "details" => details}}
  end
end
