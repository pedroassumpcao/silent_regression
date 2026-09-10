defmodule SilentRegression.Spike.SemanticLayer.PairedFixtureDraft do
  @moduledoc """
  Drafts diversity-matched open-synthesis fixture candidates from one control.

  The authoring logic is intentionally case-specific fixture data. It does not
  participate in evaluation and makes no provider calls. Each parent receives
  one meaning-preserving rewrite, one presentation-only restyle, and one
  controlled subtle regression for later human approval.
  """

  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.Provider

  @case_id "rag_open_synthesis"
  @case_version 4
  @case_fingerprint "2203ade86203a3d3a401f7a68a17f978ae9d90409be0d7b3b300957545373636"
  @sample_count 20
  @allowed_options [:clock, :fixture_set_id, :git_revision]
  @splits ~w(tuning heldout)

  @spec build(Run.t(), String.t(), String.t(), keyword()) ::
          {:ok, PairedFixtureSet.t()} | {:error, map()}
  def build(control, artifact_sha256, split, options \\ [])

  def build(%Run{} = control, artifact_sha256, split, options) when is_list(options) do
    with :ok <- validate_options(options),
         :ok <- validate_sha256(artifact_sha256),
         :ok <- validate_split(split),
         :ok <- validate_control(control),
         {:ok, samples} <- control_samples(control),
         :ok <- validate_parent_samples(samples),
         {:ok, created_at} <- timestamp(options),
         {:ok, fixture_set_id} <- fixture_set_id(control, split, options),
         {:ok, git_revision} <- git_revision(options) do
      fixtures = Enum.flat_map(samples, &draft_parent(&1, control.run_id, split))

      with :ok <- validate_derivatives(fixtures) do
        PairedFixtureSet.new(%{
          fixture_set_id: fixture_set_id,
          created_at: created_at,
          git_revision: git_revision,
          status: "candidate",
          source_control: %{
            "run_id" => control.run_id,
            "condition" => control.condition,
            "artifact_sha256" => artifact_sha256,
            "case_id" => @case_id
          },
          partition_policy: %{
            "version" => 1,
            "group_key" => "parent_observation_id",
            "splits" => PairedFixtureSet.splits()
          },
          fixtures: fixtures,
          duplicate_counts: PairedFixtureSet.duplicate_counts(fixtures)
        })
      end
    end
  end

  def build(_control, _artifact_sha256, _split, _options) do
    error(:configuration_error, "Paired fixture drafting requires a control run and options")
  end

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        error(:configuration_error, "Draft options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        error(:configuration_error, "Draft options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        error(:configuration_error, "Draft options contain unsupported keys")

      true ->
        :ok
    end
  end

  defp validate_sha256(value) do
    if is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: error(:configuration_error, "Source artifact SHA-256 is invalid")
  end

  defp validate_split(split) when split in @splits, do: :ok

  defp validate_split(split) do
    error(:configuration_error, "Draft split must be tuning or heldout", %{"actual" => split})
  end

  defp validate_control(%Run{condition: "control", provider: "openai"} = control) do
    if control.request_config["model"] == "gpt-5.6-luna",
      do: validate_case_snapshot(control),
      else: error(:incompatible_source, "Control model does not match the pilot")
  end

  defp validate_control(%Run{} = control) do
    error(:incompatible_source, "Paired fixtures require the pilot control provenance", %{
      "condition" => control.condition,
      "provider" => control.provider
    })
  end

  defp validate_case_snapshot(control) do
    case Enum.find(control.cases, &(&1.id == @case_id)) do
      %{version: @case_version, fingerprint: @case_fingerprint} ->
        :ok

      case_definition ->
        error(:incompatible_source, "Open-synthesis case snapshot is not frozen v4", %{
          "actual" =>
            if(case_definition,
              do: %{
                "version" => case_definition.version,
                "fingerprint" => case_definition.fingerprint
              },
              else: nil
            )
        })
    end
  end

  defp control_samples(control) do
    samples =
      control.samples
      |> Enum.filter(&(&1["case_id"] == @case_id))
      |> Enum.sort_by(& &1["sample_index"])

    if length(samples) == @sample_count,
      do: {:ok, samples},
      else:
        error(:incompatible_source, "Control must contain exactly 20 open-synthesis samples", %{
          "actual" => length(samples)
        })
  end

  defp validate_parent_samples(samples) do
    expected_indexes = Enum.to_list(0..(@sample_count - 1))
    actual_indexes = Enum.map(samples, & &1["sample_index"])
    outputs = Enum.map(samples, &get_in(&1, ["response", "output_text"]))

    cond do
      actual_indexes != expected_indexes ->
        error(:incompatible_source, "Control sample indexes must be contiguous")

      not Enum.all?(samples, &valid_parent_sample?/1) ->
        error(:incompatible_source, "Every parent sample must be successful and complete")

      Enum.uniq(outputs) != outputs ->
        error(:incompatible_source, "Parent outputs must be distinct; cycling is forbidden")

      true ->
        :ok
    end
  end

  defp valid_parent_sample?(sample) do
    sample["status"] == "ok" and get_in(sample, ["completion", "passed"]) == true and
      non_empty_string?(get_in(sample, ["response", "output_text"]))
  end

  defp validate_derivatives(fixtures) do
    outputs = Enum.map(fixtures, & &1["output_text"])

    unchanged =
      fixtures
      |> Enum.filter(&(sha256(&1["output_text"]) == &1["parent_output_sha256"]))
      |> Enum.map(& &1["fixture_id"])

    cond do
      unchanged != [] ->
        error(:authoring_error, "Every derivative must change its parent output", %{
          "unchanged_fixture_ids" => unchanged
        })

      Enum.uniq(outputs) != outputs ->
        error(:authoring_error, "Every drafted output must be distinct")

      true ->
        :ok
    end
  end

  defp draft_parent(sample, run_id, split) do
    index = sample["sample_index"]
    parent_output = get_in(sample, ["response", "output_text"])
    parent_id = "#{run_id}:#{@case_id}:#{index}"
    parent_hash = sha256(parent_output)
    meaning = meaning_preserving(parent_output, split)
    style = style_only(parent_output)
    {regression, failure_mode, rationale} = subtle_regression(parent_output, index, split)

    [
      fixture(
        index,
        split,
        "meaning_preserving",
        meaning,
        [],
        true,
        "Rewords the parent's supported rider, funding, and habitat account without changing facts or source scope."
      ),
      fixture(
        index,
        split,
        "style_only",
        style,
        [],
        true,
        "Changes only presentation by numbering the parent's existing paragraphs verbatim."
      ),
      fixture(index, split, "subtle_regression", regression, [failure_mode], false, rationale)
    ]
    |> Enum.map(
      &Map.merge(&1, %{
        "parent_observation_id" => parent_id,
        "parent_sample_index" => index,
        "parent_output_sha256" => parent_hash,
        "case_id" => @case_id
      })
    )
  end

  defp fixture(index, split, label, output, failure_modes, expected_contract_pass, rationale) do
    %{
      "fixture_id" =>
        "#{split}-open-synthesis-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}-#{String.replace(label, "_", "-")}",
      "split" => split,
      "label" => label,
      "failure_modes" => failure_modes,
      "expected_contract_pass" => expected_contract_pass,
      "rationale" => rationale,
      "output_text" => output,
      "approval" => %{"status" => "candidate", "reviewer" => nil, "reviewed_at" => nil}
    }
  end

  defp meaning_preserving(parent_output, "tuning") do
    parent_output
    |> replace_all([
      {~r/intended rider benefit/iu, "planned benefit for riders"},
      {~r/faster harbor crossing/iu, "shorter harbor trip"},
      {~r/\btypical\b/iu, "usual"},
      {~r/\breducing\b/iu, "shortening"},
      {~r/aiming to cut/iu, "seeking to shorten"},
      {~r/\bfull plan\b/iu, "complete plan"},
      {~r/\bremaining six\b/iu, "final six"},
      {~r/require a later appropriation/iu, "need a later appropriation"},
      {~r/\bCity leaders\b/u, "Municipal leaders"},
      {~r/\bmust balance\b/iu, "need to weigh"},
      {~r/within two kilometers/iu, "inside a two-kilometer radius"},
      {~r/at no more than 12 knots/iu, "at or below 12 knots"},
      {~r/\bprohibited\b/iu, "barred"}
    ])
    |> ensure_rewrite(parent_output, "Restated without changing the substance: ")
  end

  defp meaning_preserving(parent_output, "heldout") do
    parent_output
    |> replace_all([
      {~r/intended rider benefit/iu, "expected passenger benefit"},
      {~r/faster harbor crossing/iu, "quicker harbor journey"},
      {~r/\btypical\b/iu, "usual"},
      {~r/\breducing\b/iu, "cutting"},
      {~r/aiming to (?:cut|reduce)/iu, "seeking to shorten"},
      {~r/\bfull plan\b/iu, "overall proposal"},
      {~r/\bremaining six\b/iu, "last six"},
      {~r/require a later appropriation/iu, "depend on a future appropriation"},
      {~r/\bCity leaders\b/u, "Local officials"},
      {~r/\bmust balance\b/iu, "have to weigh"},
      {~r/within two kilometers/iu, "inside two kilometers"},
      {~r/at no more than 12 knots/iu, "no faster than 12 knots"},
      {~r/\bprohibited\b/iu, "not permitted"}
    ])
    |> ensure_rewrite(parent_output, "Put another way, without changing the substance: ")
  end

  defp style_only(parent_output) do
    parent_output
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {paragraph, index} ->
      "**#{index}.** #{String.trim(paragraph)}"
    end)
  end

  defp subtle_regression(parent_output, index, split) do
    mode_index = if split == "tuning", do: rem(index, 7), else: rem(index + 3, 7)

    case mode_index do
      0 ->
        {replace_crossing_time(parent_output), "wrong_fact",
         "Changes the supported target crossing time from 19 minutes to 21 minutes."}

      1 ->
        {String.replace(parent_output, "2044", "2042", global: false), "wrong_fact",
         "Changes the supported target year from 2044 to 2042."}

      2 ->
        {Regex.replace(~r/\b12(?=(?:[- ](?:electric|ferry|ferries)))/u, parent_output, "14",
           global: false
         ), "wrong_fact", "Changes the supported fleet size from 12 ferries to 14."}

      3 ->
        {replace_habitat_start(parent_output), "wrong_fact",
         "Moves the start of the supported habitat window from March to April."}

      4 ->
        {Regex.replace(~r/\b12(?=[- ]knots?)/u, parent_output, "14", global: false), "wrong_fact",
         "Changes the supported seasonal speed cap from 12 knots to 14 knots."}

      5 ->
        {reverse_pile_driving(parent_output), "constraint_reversal",
         "Reverses the supported seasonal pile-driving prohibition."}

      6 ->
        {swap_citations(parent_output), "wrong_attribution",
         "Keeps the facts but assigns every claim group to a source that does not support it."}
    end
  end

  defp replace_all(text, replacements) do
    Enum.reduce(replacements, text, fn {pattern, replacement}, output ->
      Regex.replace(pattern, output, replacement)
    end)
  end

  defp ensure_rewrite(output, parent_output, prefix) do
    if output == parent_output, do: prefix <> parent_output, else: output
  end

  defp replace_habitat_start(text) do
    text
    |> String.replace("From March through July", "From April through July", global: false)
    |> String.replace("from March through July", "from April through July", global: false)
  end

  defp replace_crossing_time(text) do
    output = String.replace(text, "19 minutes", "21 minutes", global: false)

    if output == text,
      do: String.replace(text, "19-minute", "21-minute", global: false),
      else: output
  end

  defp reverse_pile_driving(text) do
    output = String.replace(text, "prohibited", "permitted", global: false)

    if output == text,
      do: String.replace(text, "pile-driving ban", "pile-driving permission", global: false),
      else: output
  end

  defp swap_citations(text) do
    text
    |> String.replace("[transit-plan]", "[citation-a]")
    |> String.replace("[phase-one-budget]", "[citation-b]")
    |> String.replace("[habitat-rules]", "[citation-c]")
    |> String.replace("[citation-a]", "[phase-one-budget]")
    |> String.replace("[citation-b]", "[habitat-rules]")
    |> String.replace("[citation-c]", "[transit-plan]")
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp ->
        {:ok, DateTime.truncate(timestamp, :second)}

      value ->
        error(:configuration_error, "Draft clock must return a DateTime", %{
          "actual" => inspect(value)
        })
    end
  end

  defp fixture_set_id(control, split, options) do
    id =
      Keyword.get(
        options,
        :fixture_set_id,
        "semantic-pairs-#{split}-#{control.run_id}-v1"
      )

    if non_empty_string?(id),
      do: {:ok, id},
      else: error(:configuration_error, "Fixture set ID must be a non-empty string")
  end

  defp git_revision(options) do
    value = Keyword.get(options, :git_revision)

    if is_nil(value) or non_empty_string?(value),
      do: {:ok, value},
      else: error(:configuration_error, "Git revision must be nil or a non-empty string")
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp error(type, message, details \\ %{}) do
    {:error, Provider.error(type, message, details: details)}
  end
end
