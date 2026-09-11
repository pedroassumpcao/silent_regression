defmodule SilentRegression.Spike.SemanticLayer.ContractSet do
  @moduledoc """
  Versioned, monitor-specific semantic contracts for the four frozen RAG cases.

  Evaluator operations are generic. Facts, fields, source relationships, and
  abstention policy remain JSON-compatible configuration tied to the exact
  source-case version and fingerprint.
  """

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Validation

  @contract_set_id "rag-semantic-contracts-v1"
  @contract_set_version 1
  @contract_fields ~w(contract_id contract_version case_id source_case_version source_case_fingerprint checks fingerprint)

  @spec id() :: String.t()
  def id, do: @contract_set_id

  @spec version() :: pos_integer()
  def version, do: @contract_set_version

  @spec all() :: [map()]
  def all do
    [
      build("rag_structured_extract", structured_extract_checks()),
      build("rag_answer_with_citations", answer_with_citations_checks()),
      build("rag_abstain_when_unsupported", abstention_checks()),
      build("rag_open_synthesis", open_synthesis_checks())
    ]
  end

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(case_id) when is_binary(case_id) do
    case Enum.find(all(), &(&1["case_id"] == case_id)) do
      nil -> :error
      contract -> {:ok, contract}
    end
  end

  def fetch(_case_id), do: :error

  @spec metadata() :: map()
  def metadata do
    %{
      "contract_set_id" => @contract_set_id,
      "contract_set_version" => @contract_set_version,
      "fingerprint" => fingerprint()
    }
  end

  @spec fingerprint() :: String.t()
  def fingerprint do
    %{
      "contract_set_id" => @contract_set_id,
      "contract_set_version" => @contract_set_version,
      "contracts" => Enum.map(all(), &Map.take(&1, ~w(contract_id fingerprint)))
    }
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
    |> sha256()
  end

  @spec validate() :: :ok | {:error, map()}
  def validate do
    contracts = all()
    case_ids = Enum.map(contracts, & &1["case_id"])

    cond do
      Enum.uniq(case_ids) != case_ids ->
        {:error, %{type: :invalid_contract_set, reason: :duplicate_case_ids}}

      true ->
        contracts
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {contract, index}, :ok ->
          case validate_contract(contract) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, Map.put(error, :contract_index, index)}}
          end
        end)
    end
  end

  @spec validate_contract(map()) :: :ok | {:error, map()}
  def validate_contract(contract) when is_map(contract) do
    with :ok <- validate_keys(contract),
         :ok <- validate_identity(contract),
         {:ok, source_case} <- source_case(contract["case_id"]),
         :ok <- validate_source_case(contract, source_case),
         :ok <- validate_checks(contract),
         :ok <- validate_fingerprint(contract) do
      :ok
    end
  end

  def validate_contract(_contract),
    do: {:error, %{type: :invalid_contract, reason: :must_be_a_map}}

  defp build(case_id, checks) do
    {:ok, source_case} = CaseSet.fetch(case_id)

    contract = %{
      "contract_id" => "#{case_id}-semantic-v1",
      "contract_version" => 1,
      "case_id" => case_id,
      "source_case_version" => source_case.version,
      "source_case_fingerprint" => source_case.fingerprint,
      "checks" => checks
    }

    Map.put(contract, "fingerprint", contract_fingerprint(contract))
  end

  defp validate_keys(contract) do
    if Enum.sort(Map.keys(contract)) == Enum.sort(@contract_fields),
      do: :ok,
      else: {:error, %{type: :invalid_contract, reason: :unexpected_fields}}
  end

  defp validate_identity(contract) do
    cond do
      not non_empty_string?(contract["contract_id"]) ->
        {:error, %{type: :invalid_contract, reason: :invalid_contract_id}}

      not (is_integer(contract["contract_version"]) and contract["contract_version"] > 0) ->
        {:error, %{type: :invalid_contract, reason: :invalid_contract_version}}

      not non_empty_string?(contract["case_id"]) ->
        {:error, %{type: :invalid_contract, reason: :invalid_case_id}}

      true ->
        :ok
    end
  end

  defp source_case(case_id) do
    case CaseSet.fetch(case_id) do
      {:ok, source_case} -> {:ok, source_case}
      :error -> {:error, %{type: :invalid_contract, reason: :unknown_case_id}}
    end
  end

  defp validate_source_case(contract, source_case) do
    if contract["source_case_version"] == source_case.version and
         contract["source_case_fingerprint"] == source_case.fingerprint,
       do: :ok,
       else: {:error, %{type: :invalid_contract, reason: :stale_source_case}}
  end

  defp validate_checks(contract) do
    checks = contract["checks"]

    cond do
      not (is_list(checks) and checks != [] and Validation.json_value?(checks)) ->
        {:error, %{type: :invalid_contract, reason: :invalid_checks}}

      true ->
        CaseSet.validate_checks(contract["case_id"], checks)
    end
  end

  defp validate_fingerprint(contract) do
    expected = contract |> Map.delete("fingerprint") |> contract_fingerprint()

    if contract["fingerprint"] == expected,
      do: :ok,
      else: {:error, %{type: :invalid_contract, reason: :fingerprint_mismatch}}
  end

  defp contract_fingerprint(contract) do
    contract
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
    |> sha256()
  end

  defp structured_extract_checks do
    [
      json_field("project_name", ["project_name"], "Meridian Lantern"),
      json_field("launch_date", ["launch_date"], "2042-11-18"),
      json_field("city", ["city"], "Bellweather Harbor"),
      json_field("budget_usd", ["budget_usd"], 480_000, "mathematical"),
      json_field("source_ids", ["source_ids"], ["brief-7", "finance-2"])
    ]
  end

  defp answer_with_citations_checks do
    [
      attributed_fact(
        "tour_days",
        %{
          "any_of" => [
            "Wednesday and Friday",
            "Wednesdays and Fridays",
            "every Wednesday and Friday"
          ]
        },
        ["tour-schedule"]
      ),
      attributed_fact(
        "tour_start_time",
        %{"any_of" => ["10:30 a.m.", "10:30 am", "10:30"]},
        ["tour-schedule"]
      ),
      attributed_fact(
        "tour_duration",
        %{"any_of" => ["75 minutes", "75-minute", "seventy-five minutes"]},
        ["tour-schedule"]
      ),
      attributed_fact(
        "booking_notice",
        %{"any_of" => ["24 hours", "twenty-four hours", "one day"]},
        ["booking-policy"]
      ),
      %{
        "type" => "forbidden_fact",
        "id" => "unsupported_free_tour_claim",
        "any_of" => ["free guided tours", "guided tours are free", "tours are free", "free tours"]
      },
      allowed_sources(["tour-schedule", "booking-policy"])
    ]
  end

  defp abstention_checks do
    [
      %{
        "type" => "abstains",
        "accepted_phrases" => [
          "cannot be determined",
          "does not provide",
          "does not specify",
          "not provided",
          "not specified",
          "not stated",
          "insufficient information"
        ],
        "forbidden_patterns" => [
          "\\b\\d+\\s+(?:paid\\s+)?weeks?\\b",
          "\\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\s+(?:paid\\s+)?weeks?\\b"
        ]
      },
      allowed_sources(["benefits-guide"])
    ]
  end

  defp open_synthesis_checks do
    [
      attributed_fact(
        "full_fleet",
        %{
          "any_of" => [
            "12 ferries",
            "12 ferry",
            "12-ferry",
            "12 electric ferries",
            "12 electric ferry",
            "twelve ferries",
            "twelve ferry",
            "twelve electric ferries",
            "twelve electric ferry"
          ]
        },
        ["transit-plan", "phase-one-budget"]
      ),
      %{"type" => "required_fact", "id" => "electric_fleet", "any_of" => ["electric"]},
      attributed_fact(
        "phase_one_fleet",
        %{
          "groups" => [
            [
              "phase one",
              "first phase",
              "initial rollout",
              "rollout will begin",
              "approved funding"
            ],
            [
              "six ferries",
              "6 ferries",
              "first six ferries",
              "first six of the planned 12 ferries",
              "first six of 12 ferries",
              "six of the planned 12 ferries",
              "six of 12 ferries"
            ]
          ],
          "max_span_tokens" => 24
        },
        ["phase-one-budget"]
      ),
      attributed_fact(
        "remaining_fleet_funding",
        %{
          "groups" => [
            [
              "remaining six",
              "last six",
              "final six",
              "other six",
              "six more",
              "completing the planned 12",
              "completing planned 12"
            ],
            [
              "later appropriation",
              "future appropriation",
              "another appropriation",
              "later funding",
              "future funding"
            ]
          ],
          "max_span_tokens" => 24
        },
        ["phase-one-budget"]
      ),
      attributed_fact(
        "crossing_target",
        %{
          "groups" => [
            ["19 minutes", "19-minute", "34 minutes to 19"],
            ["2044"]
          ],
          "max_span_tokens" => 32
        },
        ["transit-plan"]
      ),
      attributed_fact(
        "habitat_speed_limit",
        %{"any_of" => ["12 knots", "twelve knots"]},
        ["habitat-rules"]
      ),
      attributed_fact(
        "habitat_period",
        %{"any_of" => ["March through July", "March to July", "between March and July"]},
        ["habitat-rules"]
      ),
      attributed_fact(
        "pile_driving_prohibition",
        %{
          "groups" => [
            ["pile driving", "pile-driving"],
            ["prohibited", "not permitted", "barred", "ban"]
          ],
          "max_span_tokens" => 16
        },
        ["habitat-rules"]
      ),
      %{
        "type" => "forbidden_fact",
        "id" => "unsupported_fare_reduction",
        "any_of" => [
          "lower passenger fares by 25 percent",
          "reduce passenger fares by 25 percent",
          "25 percent lower passenger fares"
        ]
      },
      allowed_sources(["transit-plan", "phase-one-budget", "habitat-rules"])
    ]
  end

  defp json_field(id, path, expected, numeric_comparison \\ "strict") do
    %{
      "type" => "json_field_equals",
      "id" => id,
      "path" => path,
      "expected" => expected,
      "numeric_comparison" => numeric_comparison
    }
  end

  defp attributed_fact(id, fact, allowed_source_ids) do
    %{
      "type" => "fact_source_attribution",
      "id" => id,
      "fact" => fact,
      "allowed_source_ids" => allowed_source_ids
    }
  end

  defp allowed_sources(source_ids) do
    %{
      "type" => "allowed_source_ids",
      "source_ids" => source_ids,
      "require_at_least_one" => true
    }
  end

  defp canonicalize(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} -> {key, canonicalize(nested_value)} end)
      |> Enum.sort_by(fn {key, _nested_value} -> key end)

    {:map, entries}
  end

  defp canonicalize(value) when is_list(value), do: {:list, Enum.map(value, &canonicalize/1)}
  defp canonicalize(value), do: value

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
