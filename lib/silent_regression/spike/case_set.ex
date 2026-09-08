defmodule SilentRegression.Spike.CaseSet do
  @moduledoc """
  The frozen, versioned RAG cases used by the feasibility spike.

  All source material is fictional. A case fingerprint covers fields that
  affect model behavior or deterministic evaluation while excluding purely
  descriptive metadata such as tags and descriptions.
  """

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Validation

  @spec all() :: [Case.t()]
  def all do
    [
      structured_extract(),
      answer_with_citations(),
      abstain_when_unsupported(),
      open_synthesis()
    ]
  end

  @spec fetch(String.t()) :: {:ok, Case.t()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> :error
      case_definition -> {:ok, case_definition}
    end
  end

  def fetch(_id), do: :error

  @doc """
  Computes the SHA-256 fingerprint used to determine case compatibility.

  Map keys are sorted recursively before hashing, so semantically identical
  check specifications produce the same digest regardless of map order.
  """
  @spec fingerprint(Case.t()) :: String.t()
  def fingerprint(%Case{} = case_definition) do
    case_definition
    |> fingerprint_payload()
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec validate([Case.t()]) :: :ok | {:error, map()}
  def validate(cases \\ all())

  def validate(cases) when is_list(cases) and cases != [] do
    with :ok <- validate_unique_ids(cases) do
      cases
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {case_definition, index}, :ok ->
        case validate_case(case_definition) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, Map.put_new(error, :case_index, index)}}
        end
      end)
    end
  end

  def validate(_cases) do
    {:error, %{type: :invalid_case_set, reason: :must_be_a_non_empty_list}}
  end

  defp structured_extract do
    build_case(%{
      id: "rag_structured_extract",
      version: 1,
      category: "rag_structured",
      description: "Extract facts spread across two retrieved passages into strict JSON.",
      system_prompt: "Use only the supplied sources. Do not add outside information.",
      context: """
      [brief-7]
      The Meridian Lantern pilot will open on November 18, 2042, in Bellweather Harbor.

      [finance-2]
      The approved budget for the Meridian Lantern pilot is $480,000.
      """,
      question: """
      Extract the project name, launch date, city, approved budget in US dollars, and the
      source IDs that support those fields.
      """,
      response_format: """
      Return only a JSON object with exactly these keys: project_name, launch_date,
      city, budget_usd, source_ids. Use YYYY-MM-DD for the date and a JSON number for
      the budget. Do not wrap the JSON in a Markdown fence.
      """,
      checks: [
        %{
          "type" => "json_equals",
          "allow_extra_keys" => false,
          "numeric_comparison" => "mathematical",
          "expected" => %{
            "project_name" => "Meridian Lantern",
            "launch_date" => "2042-11-18",
            "city" => "Bellweather Harbor",
            "budget_usd" => 480_000,
            "source_ids" => ["brief-7", "finance-2"]
          }
        }
      ],
      tags: ["rag", "structured-output", "multi-source"]
    })
  end

  defp answer_with_citations do
    build_case(%{
      id: "rag_answer_with_citations",
      version: 1,
      category: "rag_grounded_answer",
      description: "Answer a multi-source visitor question with supporting source IDs.",
      system_prompt: "Use only the supplied sources and cite the source ID for every claim.",
      context: """
      [tour-schedule]
      Guided greenhouse tours at Solmere Conservatory begin at 10:30 a.m. every
      Wednesday and Friday. Each guided tour lasts 75 minutes.

      [booking-policy]
      Guided tours must be reserved at least 24 hours before their scheduled start.
      """,
      question: "When do guided tours run, how long are they, and how far ahead must I book?",
      response_format: """
      Answer in one or two concise sentences. Place the supporting source ID in square
      brackets immediately after the claim it supports.
      """,
      checks: [
        %{
          "type" => "required_fact",
          "id" => "tour_days",
          "any_of" => [
            "Wednesday and Friday",
            "Wednesdays and Fridays",
            "every Wednesday and Friday"
          ]
        },
        %{
          "type" => "required_fact",
          "id" => "tour_start_time",
          "any_of" => ["10:30 a.m.", "10:30 am", "10:30"]
        },
        %{
          "type" => "required_fact",
          "id" => "tour_duration",
          "any_of" => ["75 minutes", "75-minute", "seventy-five minutes"]
        },
        %{
          "type" => "required_fact",
          "id" => "booking_notice",
          "any_of" => ["24 hours", "twenty-four hours", "one day"]
        },
        %{
          "type" => "required_source_ids",
          "source_ids" => ["tour-schedule", "booking-policy"]
        }
      ],
      tags: ["rag", "citations", "grounding", "multi-source"]
    })
  end

  defp abstain_when_unsupported do
    build_case(%{
      id: "rag_abstain_when_unsupported",
      version: 1,
      category: "rag_abstention",
      description: "Decline to answer when the retrieved context omits the requested fact.",
      system_prompt: """
      Use only the supplied source. If it does not answer the question, say that the
      answer cannot be determined from the context and do not guess.
      """,
      context: """
      [benefits-guide]
      Northwind Workshop employees receive 22 days of annual leave. They may work
      remotely up to two days per week and can claim up to $900 per year for approved
      professional training.
      """,
      question: "How many weeks of paid parental leave do Northwind Workshop employees receive?",
      response_format: "Answer in one concise sentence and cite the source ID if applicable.",
      checks: [
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
        }
      ],
      tags: ["rag", "abstention", "unsupported-question"]
    })
  end

  defp open_synthesis do
    build_case(%{
      id: "rag_open_synthesis",
      version: 2,
      category: "rag_open_synthesis",
      description:
        "Synthesize a rollout plan and its tradeoffs without a single reference answer.",
      system_prompt: """
      Use only the supplied sources. Distinguish the full plan from the funded first
      phase and explain material environmental constraints.
      """,
      context: """
      [transit-plan]
      Larkspur Bay plans to convert the vacant Dock 3 warehouse into a charging terminal
      and introduce a fleet of 12 electric ferries. The target is to reduce the typical
      harbor crossing from 34 minutes to 19 minutes by 2044.

      [habitat-rules]
      From March through July, ferries operating within two kilometers of the Orison
      nesting islands must remain at or below 12 knots. Pile-driving near the islands is
      prohibited during the same period.

      [phase-one-budget]
      Approved phase-one funding covers the Dock 3 terminal conversion and the first six
      ferries. Purchasing the remaining six ferries requires a later appropriation.
      """,
      question: """
      Summarize the intended rider benefit, the rollout constraint, and the environmental
      tradeoff city leaders must manage.
      """,
      response_format: """
      Write two or three concise paragraphs. Cite supporting source IDs in square brackets.
      Multiple phrasings and structures are acceptable.
      """,
      checks: [
        %{
          "type" => "required_fact",
          "id" => "full_fleet",
          "any_of" => [
            "12 electric ferries",
            "12 electric ferry",
            "twelve electric ferries",
            "fleet of 12"
          ]
        },
        %{
          "type" => "required_fact_groups",
          "id" => "phase_one_fleet",
          "groups" => [
            ["phase one", "first phase", "initial rollout", "rollout will begin"],
            ["six ferries", "6 ferries"]
          ],
          "max_span_tokens" => 24
        },
        %{
          "type" => "required_fact_groups",
          "id" => "crossing_target",
          "groups" => [
            ["19 minutes", "19-minute"],
            ["2044"]
          ],
          "max_span_tokens" => 32
        },
        %{
          "type" => "required_fact",
          "id" => "habitat_speed_limit",
          "any_of" => ["12 knots", "twelve knots"]
        },
        %{
          "type" => "required_fact",
          "id" => "habitat_period",
          "any_of" => ["March through July", "March to July", "between March and July"]
        },
        %{
          "type" => "required_source_ids",
          "source_ids" => ["transit-plan", "habitat-rules", "phase-one-budget"]
        }
      ],
      tags: ["rag", "open-ended", "synthesis", "tradeoffs", "multi-source"]
    })
  end

  defp build_case(attributes) do
    {:ok, case_without_fingerprint} = Case.new(attributes)
    fingerprint = fingerprint(case_without_fingerprint)
    {:ok, case_definition} = Case.new(Map.put(attributes, :fingerprint, fingerprint))
    case_definition
  end

  defp fingerprint_payload(case_definition) do
    %{
      "id" => case_definition.id,
      "version" => case_definition.version,
      "category" => case_definition.category,
      "system_prompt" => case_definition.system_prompt,
      "context" => case_definition.context,
      "question" => case_definition.question,
      "response_format" => case_definition.response_format,
      "checks" => case_definition.checks
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

  defp validate_unique_ids(cases) do
    ids = Enum.map(cases, &case_id/1)

    if Enum.uniq(ids) == ids do
      :ok
    else
      {:error, %{type: :invalid_case_set, reason: :duplicate_case_ids}}
    end
  end

  defp case_id(%Case{id: id}), do: id
  defp case_id(_case_definition), do: nil

  defp validate_case(%Case{} = case_definition) do
    with :ok <- Case.validate(case_definition),
         :ok <- validate_fingerprint(case_definition),
         :ok <- validate_checks(case_definition) do
      :ok
    end
  end

  defp validate_case(_case_definition) do
    {:error, %{type: :invalid_case_set, reason: :expected_case_struct}}
  end

  defp validate_fingerprint(case_definition) do
    expected = fingerprint(case_definition)

    if case_definition.fingerprint == expected do
      :ok
    else
      {:error,
       %{
         type: :fingerprint_mismatch,
         case_id: case_definition.id,
         expected: expected,
         actual: case_definition.fingerprint
       }}
    end
  end

  defp validate_checks(case_definition) do
    case_definition.checks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {check, index}, :ok ->
      case validate_check(check) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            %{
              type: :invalid_check_spec,
              case_id: case_definition.id,
              check_index: index,
              reason: reason
            }}}
      end
    end)
  end

  defp validate_check(%{
         "type" => "json_equals",
         "expected" => expected,
         "allow_extra_keys" => allow_extra_keys,
         "numeric_comparison" => numeric_comparison
       }) do
    cond do
      not (is_map(expected) and Validation.json_value?(expected)) ->
        {:error, :invalid_json_expected_value}

      not is_boolean(allow_extra_keys) ->
        {:error, :invalid_allow_extra_keys}

      numeric_comparison not in ["strict", "mathematical"] ->
        {:error, :invalid_numeric_comparison}

      true ->
        :ok
    end
  end

  defp validate_check(%{"type" => "required_fact", "id" => id, "any_of" => alternatives}) do
    with :ok <- validate_non_empty_string(id, :invalid_fact_id),
         :ok <- validate_non_empty_string_list(alternatives, :invalid_fact_alternatives) do
      :ok
    end
  end

  defp validate_check(%{
         "type" => "required_fact_groups",
         "id" => id,
         "groups" => groups,
         "max_span_tokens" => max_span_tokens
       }) do
    with :ok <- validate_non_empty_string(id, :invalid_fact_id),
         :ok <- validate_non_empty_string_groups(groups, :invalid_fact_groups),
         :ok <- validate_positive_integer(max_span_tokens, :invalid_max_span_tokens) do
      :ok
    end
  end

  defp validate_check(%{"type" => "forbidden_fact", "id" => id, "any_of" => alternatives}) do
    with :ok <- validate_non_empty_string(id, :invalid_fact_id),
         :ok <- validate_non_empty_string_list(alternatives, :invalid_fact_alternatives) do
      :ok
    end
  end

  defp validate_check(%{"type" => "normalized_equals", "expected" => expected}) do
    validate_non_empty_string(expected, :invalid_normalized_expected_value)
  end

  defp validate_check(%{"type" => "required_source_ids", "source_ids" => source_ids}) do
    validate_non_empty_string_list(source_ids, :invalid_source_ids)
  end

  defp validate_check(%{
         "type" => "abstains",
         "accepted_phrases" => accepted_phrases,
         "forbidden_patterns" => forbidden_patterns
       }) do
    with :ok <-
           validate_non_empty_string_list(accepted_phrases, :invalid_abstention_phrases),
         :ok <- validate_non_empty_string_list(forbidden_patterns, :invalid_forbidden_patterns),
         :ok <- validate_regexes(forbidden_patterns) do
      :ok
    end
  end

  defp validate_check(_check), do: {:error, :unsupported_or_malformed_check}

  defp validate_non_empty_string(value, error) do
    if is_binary(value) and String.trim(value) != "", do: :ok, else: {:error, error}
  end

  defp validate_non_empty_string_list(values, error) do
    if is_list(values) and values != [] and
         Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_non_empty_string_groups(groups, error) do
    if is_list(groups) and groups != [] and
         Enum.all?(groups, fn group ->
           is_list(group) and group != [] and
             Enum.all?(group, &(is_binary(&1) and String.trim(&1) != ""))
         end) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_positive_integer(value, error) do
    if is_integer(value) and value > 0, do: :ok, else: {:error, error}
  end

  defp validate_regexes(patterns) do
    Enum.reduce_while(patterns, :ok, fn pattern, :ok ->
      case Regex.compile(pattern, "iu") do
        {:ok, _regex} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :invalid_forbidden_pattern}}
      end
    end)
  end
end
