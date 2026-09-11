defmodule SilentRegression.Spike.SemanticLayer.ContractRescore do
  @moduledoc """
  Rescores approved authoring and paired fixtures with the frozen contract set.

  The evaluator reads fixture text and writes a separate result. Source
  observations and approved fixture artifacts are never changed.
  """

  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.SemanticLayer.ContractEvaluator
  alias SilentRegression.Spike.SemanticLayer.ContractRescoreResult
  alias SilentRegression.Spike.SemanticLayer.ContractSet
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet

  @allowed_options [:clock, :evaluation_id, :git_revision]

  @spec run(map(), PairedFixtureSet.t(), String.t(), keyword()) ::
          {:ok, ContractRescoreResult.t()} | {:error, map()}
  def run(authoring, paired, paired_sha256, options \\ [])

  def run(authoring, %PairedFixtureSet{} = paired, paired_sha256, options)
      when is_map(authoring) and is_list(options) do
    with :ok <- validate_options(options),
         :ok <- ContractSet.validate(),
         :ok <- validate_authoring(authoring),
         {:ok, paired_split} <- validate_paired(paired),
         :ok <- validate_sha256(paired_sha256),
         {:ok, created_at} <- timestamp(options),
         {:ok, evaluation_id} <- evaluation_id(paired_split, created_at, options),
         {:ok, git_revision} <- git_revision(options),
         fixtures <- normalize_authoring(authoring) ++ normalize_paired(paired),
         :ok <- validate_unique_fixture_ids(fixtures),
         {:ok, results} <- evaluate_fixtures(fixtures) do
      ContractRescoreResult.new(%{
        evaluation_id: evaluation_id,
        created_at: created_at,
        git_revision: git_revision,
        contract_set: ContractSet.metadata(),
        sources: sources(authoring, paired, paired_sha256, paired_split),
        summary: ContractRescoreResult.summary(results),
        results: results,
        provider_calls: 0
      })
    end
  end

  def run(_authoring, _paired, _paired_sha256, _options) do
    error(
      :configuration_error,
      "Contract rescore requires approved authoring and paired fixtures plus options"
    )
  end

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        error(:configuration_error, "Rescore options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        error(:configuration_error, "Rescore options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        error(:configuration_error, "Rescore options contain unsupported keys")

      true ->
        :ok
    end
  end

  defp validate_authoring(%{
         "manifest" => %{"status" => "approved", "review_required" => false},
         "manifest_sha256" => manifest_sha256,
         "fixtures" => fixtures
       })
       when is_list(fixtures) and fixtures != [] do
    validate_sha256(manifest_sha256)
  end

  defp validate_authoring(_authoring) do
    error(:invalid_fixture_source, "Task 10 authoring fixtures must be approved")
  end

  defp validate_paired(paired) do
    with :ok <- validate_paired_contract(paired),
         [split] <- paired.fixtures |> Enum.map(& &1["split"]) |> Enum.uniq(),
         true <- split in ~w(tuning heldout) do
      {:ok, split}
    else
      {:error, error} ->
        {:error, error}

      _invalid ->
        error(
          :invalid_fixture_source,
          "Paired fixtures must contain one tuning or held-out split"
        )
    end
  end

  defp validate_paired_contract(paired) do
    case PairedFixtureSet.validate(paired) do
      :ok when paired.status == "approved" ->
        :ok

      :ok ->
        error(:invalid_fixture_source, "Paired fixture set must be approved")

      {:error, reason} ->
        error(:invalid_fixture_source, "Paired fixture set is invalid", %{
          "reason" => inspect(reason)
        })
    end
  end

  defp validate_sha256(value) do
    if is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: error(:configuration_error, "Artifact SHA-256 is invalid")
  end

  defp normalize_authoring(authoring) do
    Enum.map(authoring["fixtures"], fn fixture ->
      %{
        "fixture_id" => fixture["id"],
        "case_id" => fixture["case_id"],
        "split" => "authoring",
        "label" => fixture["variant_type"],
        "failure_modes" => fixture["failure_modes"],
        "expected_contract_pass" => fixture["intended_label"] == "acceptable",
        "output_text" => fixture["output_text"]
      }
    end)
  end

  defp normalize_paired(paired) do
    Enum.map(paired.fixtures, fn fixture ->
      Map.take(
        fixture,
        ~w(fixture_id case_id split label failure_modes expected_contract_pass output_text)
      )
    end)
  end

  defp validate_unique_fixture_ids(fixtures) do
    fixture_ids = Enum.map(fixtures, & &1["fixture_id"])

    if Enum.uniq(fixture_ids) == fixture_ids,
      do: :ok,
      else: error(:invalid_fixture_source, "Fixture IDs must be unique across sources")
  end

  defp evaluate_fixtures(fixtures) do
    fixtures
    |> Enum.reduce_while({:ok, []}, fn fixture, {:ok, results} ->
      with {:ok, contract} <- fetch_contract(fixture["case_id"]),
           {:ok, evaluation} <- ContractEvaluator.evaluate(contract, fixture["output_text"]) do
        result = %{
          "fixture_id" => fixture["fixture_id"],
          "case_id" => fixture["case_id"],
          "split" => fixture["split"],
          "label" => fixture["label"],
          "failure_modes" => fixture["failure_modes"],
          "expected_contract_pass" => fixture["expected_contract_pass"],
          "actual_contract_pass" => evaluation["all_passed"],
          "matched_expectation" => fixture["expected_contract_pass"] == evaluation["all_passed"],
          "contract_id" => contract["contract_id"],
          "contract_fingerprint" => contract["fingerprint"],
          "checks" => evaluation["checks"]
        }

        {:cont, {:ok, [result | results]}}
      else
        {:error, reason} ->
          {:halt,
           error(:evaluation_failed, "Could not evaluate fixture", %{
             "fixture_id" => fixture["fixture_id"],
             "reason" => inspect(reason)
           })}
      end
    end)
    |> then(fn
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, error} -> {:error, error}
    end)
  end

  defp fetch_contract(case_id) do
    case ContractSet.fetch(case_id) do
      {:ok, contract} ->
        {:ok, contract}

      :error ->
        error(:invalid_fixture_source, "Fixture references a case without a contract", %{
          "case_id" => case_id
        })
    end
  end

  defp sources(authoring, paired, paired_sha256, paired_split) do
    [
      %{
        "source_type" => "task_10_authoring",
        "artifact_id" => "task-10-approved-fixtures",
        "artifact_sha256" => authoring["manifest_sha256"],
        "split" => "authoring",
        "status" => "approved"
      },
      %{
        "source_type" => "paired_fixture_set",
        "artifact_id" => paired.fixture_set_id,
        "artifact_sha256" => paired_sha256,
        "split" => paired_split,
        "status" => paired.status
      }
    ]
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp ->
        {:ok, DateTime.truncate(timestamp, :second)}

      value ->
        error(:configuration_error, "Rescore clock must return a DateTime", %{
          "actual" => inspect(value)
        })
    end
  end

  defp evaluation_id(split, created_at, options) do
    id =
      Keyword.get(
        options,
        :evaluation_id,
        "semantic-contract-rescore-#{split}-#{Calendar.strftime(created_at, "%Y%m%dT%H%M%SZ")}-#{System.unique_integer([:positive, :monotonic])}"
      )

    if non_empty_string?(id),
      do: {:ok, id},
      else: error(:configuration_error, "Evaluation ID must be a non-empty string")
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
