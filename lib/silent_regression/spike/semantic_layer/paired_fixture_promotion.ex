defmodule SilentRegression.Spike.SemanticLayer.PairedFixturePromotion do
  @moduledoc """
  Promotes a completely reviewed candidate fixture set into a new approved set.

  Promotion never mutates the candidate. It copies the reviewed judgments into
  a separately identified artifact and adds the shared reviewer and timestamp
  to every fixture approval record.
  """

  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet

  @allowed_options [:clock, :fixture_set_id, :git_revision]

  @spec promote(PairedFixtureSet.t(), String.t(), keyword()) ::
          {:ok, PairedFixtureSet.t()} | {:error, map()}
  def promote(candidate, reviewer, options \\ [])

  def promote(%PairedFixtureSet{} = candidate, reviewer, options) when is_list(options) do
    with :ok <- validate_options(options),
         :ok <- validate_candidate(candidate),
         :ok <- validate_reviewer(reviewer),
         {:ok, reviewed_at} <- timestamp(options),
         {:ok, fixture_set_id} <- fixture_set_id(candidate, options),
         {:ok, git_revision} <- git_revision(options) do
      fixtures =
        Enum.map(candidate.fixtures, fn fixture ->
          Map.put(fixture, "approval", %{
            "status" => "approved",
            "reviewer" => reviewer,
            "reviewed_at" => DateTime.to_iso8601(reviewed_at)
          })
        end)

      PairedFixtureSet.new(%{
        fixture_set_id: fixture_set_id,
        created_at: reviewed_at,
        git_revision: git_revision,
        status: "approved",
        source_control: candidate.source_control,
        partition_policy: candidate.partition_policy,
        fixtures: fixtures,
        duplicate_counts: PairedFixtureSet.duplicate_counts(fixtures)
      })
    end
  end

  def promote(_candidate, _reviewer, _options) do
    error(
      :configuration_error,
      "Fixture promotion requires a paired candidate set, reviewer, and options"
    )
  end

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        error(:configuration_error, "Promotion options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        error(:configuration_error, "Promotion options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        error(:configuration_error, "Promotion options contain unsupported keys")

      true ->
        :ok
    end
  end

  defp validate_candidate(candidate) do
    with :ok <- validate_fixture_set(candidate) do
      cond do
        candidate.status != "candidate" ->
          error(:invalid_candidate, "Only candidate fixture sets can be promoted")

        not Enum.all?(candidate.fixtures, &candidate_approval?/1) ->
          error(:invalid_candidate, "Every fixture must still have candidate approval status")

        true ->
          :ok
      end
    end
  end

  defp validate_fixture_set(candidate) do
    case PairedFixtureSet.validate(candidate) do
      :ok ->
        :ok

      {:error, details} ->
        error(:invalid_candidate, "Candidate fixture set is invalid", %{
          "validation_error" => inspect(details)
        })
    end
  end

  defp candidate_approval?(fixture) do
    fixture["approval"] == %{
      "status" => "candidate",
      "reviewer" => nil,
      "reviewed_at" => nil
    }
  end

  defp validate_reviewer(reviewer) do
    if non_empty_string?(reviewer),
      do: :ok,
      else: error(:configuration_error, "Reviewer must be a non-empty string")
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp ->
        {:ok, DateTime.truncate(timestamp, :second)}

      value ->
        error(:configuration_error, "Promotion clock must return a DateTime", %{
          "actual" => inspect(value)
        })
    end
  end

  defp fixture_set_id(candidate, options) do
    id = Keyword.get(options, :fixture_set_id, candidate.fixture_set_id <> "-approved")

    cond do
      not non_empty_string?(id) ->
        error(:configuration_error, "Approved fixture set ID must be a non-empty string")

      id == candidate.fixture_set_id ->
        error(:configuration_error, "Approved fixture set ID must differ from its candidate")

      true ->
        {:ok, id}
    end
  end

  defp git_revision(options) do
    value = Keyword.get(options, :git_revision)

    if is_nil(value) or non_empty_string?(value),
      do: {:ok, value},
      else: error(:configuration_error, "Git revision must be nil or a non-empty string")
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp error(type, message, details \\ %{}) do
    {:error, Provider.error(type, message, details: details)}
  end
end
