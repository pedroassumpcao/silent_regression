defmodule SilentRegression.Spike.DeterministicChecks do
  @moduledoc """
  Deterministic quality checks for the frozen spike cases.

  Fact normalization applies Unicode NFKC normalization and full Unicode case
  folding, replaces punctuation with spaces, and collapses whitespace.
  Phrase checks compare complete normalized token sequences, so `six` does not
  match `sixteen`. Source citations are deliberately stricter: an ID only
  counts when it appears exactly inside square brackets.

  JSON checks accept either a bare JSON object or one JSON object enclosed by a
  single Markdown fence. Prose outside the object is invalid. When extra keys
  are allowed, the expected object is compared as a recursive subset. Numeric
  comparison is either type-sensitive (`strict`) or treats equal integers and
  floats as equal (`mathematical`). Array order always matters.
  """

  alias SilentRegression.Spike.Case

  @json_fence ~r/\A```(?:json)?[ \t]*\r?\n(?<body>.*?)\r?\n```[ \t]*\z/is
  @supported_check_types [
    "json_equals",
    "normalized_equals",
    "required_fact",
    "forbidden_fact",
    "required_source_ids",
    "abstains"
  ]

  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | map()
  @type check_result :: %{required(String.t()) => json_value()}
  @type evaluation :: %{required(String.t()) => json_value()}

  @doc """
  Evaluates every configured check and returns an explainable aggregate.

  A failed deterministic check is a successful evaluation with `passed: false`;
  only invalid arguments or an invalid case contract return `{:error, error}`.
  """
  @spec evaluate(Case.t(), String.t()) :: {:ok, evaluation()} | {:error, map()}
  def evaluate(%Case{} = case_definition, output_text) when is_binary(output_text) do
    with true <- String.valid?(output_text),
         :ok <- Case.validate(case_definition) do
      check_results =
        case_definition.checks
        |> Enum.with_index()
        |> Enum.map(fn {check, index} -> evaluate_check(check, output_text, index) end)

      {:ok, aggregate(case_definition.id, check_results)}
    else
      false ->
        {:error, %{type: :invalid_output, reason: :must_be_valid_utf8}}

      {:error, error} ->
        {:error, %{type: :invalid_case, reason: error}}
    end
  end

  def evaluate(%Case{}, _output_text) do
    {:error, %{type: :invalid_output, reason: :must_be_a_string}}
  end

  def evaluate(_case_definition, _output_text) do
    {:error, %{type: :invalid_case, reason: :must_be_a_case_struct}}
  end

  @doc """
  Returns the canonical representation used by phrase and exact-label checks.
  """
  @spec normalize_fact(String.t()) :: String.t()
  def normalize_fact(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> :unicode.characters_to_nfkc_binary()
      |> :string.casefold()
      |> :unicode.characters_to_binary()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
    else
      ""
    end
  end

  defp evaluate_check(check, output_text, index) when is_map(check) do
    {passed, reason, details} =
      if String.trim(output_text) == "" do
        {false, "empty_output", %{}}
      else
        do_evaluate_check(check, output_text)
      end

    check
    |> base_result(index, passed, reason)
    |> Map.put("details", details)
  end

  defp evaluate_check(_check, output_text, index) do
    reason = if String.trim(output_text) == "", do: "empty_output", else: "malformed_check"

    %{
      "check_index" => index,
      "type" => "unknown",
      "passed" => false,
      "reason" => reason,
      "details" => %{}
    }
  end

  defp do_evaluate_check(
         %{
           "type" => "json_equals",
           "expected" => expected,
           "allow_extra_keys" => allow_extra_keys,
           "numeric_comparison" => numeric_comparison
         },
         output_text
       )
       when is_map(expected) and is_boolean(allow_extra_keys) and
              numeric_comparison in ["strict", "mathematical"] do
    case decode_json_object(output_text) do
      {:ok, actual} ->
        mismatches =
          compare_json(actual, expected, allow_extra_keys, numeric_comparison, [])

        if mismatches == [] do
          {true, "matched", %{"mismatches" => []}}
        else
          {false, "json_mismatch", %{"mismatches" => mismatches}}
        end

      {:error, reason} ->
        {false, Atom.to_string(reason), %{}}
    end
  end

  defp do_evaluate_check(
         %{"type" => "normalized_equals", "expected" => expected},
         output_text
       )
       when is_binary(expected) do
    normalized_actual = normalize_fact(output_text)
    normalized_expected = normalize_fact(expected)
    passed = normalized_expected != "" and normalized_actual == normalized_expected

    details = %{
      "normalized_actual" => normalized_actual,
      "normalized_expected" => normalized_expected
    }

    if passed,
      do: {true, "matched", details},
      else: {false, "normalized_value_mismatch", details}
  end

  defp do_evaluate_check(
         %{"type" => "required_fact", "any_of" => alternatives} = check,
         output_text
       )
       when is_list(alternatives) do
    with true <- valid_phrases?(alternatives) do
      matched_alternative = Enum.find(alternatives, &contains_fact?(output_text, &1))

      details = %{
        "fact_id" => Map.get(check, "id"),
        "alternatives" => alternatives,
        "matched_alternative" => matched_alternative
      }

      if matched_alternative,
        do: {true, "matched", details},
        else: {false, "required_fact_missing", details}
    else
      false -> {false, "malformed_check", %{}}
    end
  end

  defp do_evaluate_check(
         %{"type" => "forbidden_fact", "any_of" => alternatives} = check,
         output_text
       )
       when is_list(alternatives) do
    with true <- valid_phrases?(alternatives) do
      matches = Enum.filter(alternatives, &contains_fact?(output_text, &1))

      details = %{
        "fact_id" => Map.get(check, "id"),
        "forbidden_alternatives" => alternatives,
        "matched_alternatives" => matches
      }

      if matches == [],
        do: {true, "forbidden_fact_absent", details},
        else: {false, "forbidden_fact_present", details}
    else
      false -> {false, "malformed_check", %{}}
    end
  end

  defp do_evaluate_check(
         %{"type" => "required_source_ids", "source_ids" => source_ids},
         output_text
       )
       when is_list(source_ids) do
    with true <- valid_phrases?(source_ids) do
      missing_source_ids =
        Enum.reject(source_ids, &String.contains?(output_text, "[#{&1}]"))

      details = %{
        "required_source_ids" => source_ids,
        "missing_source_ids" => missing_source_ids
      }

      if missing_source_ids == [],
        do: {true, "all_source_ids_present", details},
        else: {false, "source_ids_missing", details}
    else
      false -> {false, "malformed_check", %{}}
    end
  end

  defp do_evaluate_check(
         %{
           "type" => "abstains",
           "accepted_phrases" => accepted_phrases,
           "forbidden_patterns" => forbidden_patterns
         },
         output_text
       )
       when is_list(accepted_phrases) and is_list(forbidden_patterns) do
    with true <- valid_phrases?(accepted_phrases),
         true <- valid_phrases?(forbidden_patterns),
         {:ok, compiled_patterns} <- compile_patterns(forbidden_patterns) do
      matched_phrase = Enum.find(accepted_phrases, &contains_fact?(output_text, &1))

      matched_forbidden_patterns =
        for {source, regex} <- compiled_patterns,
            Regex.match?(regex, output_text),
            do: source

      details = %{
        "matched_phrase" => matched_phrase,
        "matched_forbidden_patterns" => matched_forbidden_patterns
      }

      cond do
        matched_forbidden_patterns != [] ->
          {false, "forbidden_claim_present", details}

        is_nil(matched_phrase) ->
          {false, "abstention_missing", details}

        true ->
          {true, "abstention_confirmed", details}
      end
    else
      false -> {false, "malformed_check", %{}}
      {:error, _reason} -> {false, "malformed_check", %{}}
    end
  end

  defp do_evaluate_check(%{"type" => type}, _output_text)
       when type in @supported_check_types do
    {false, "malformed_check", %{}}
  end

  defp do_evaluate_check(%{"type" => type}, _output_text) when is_binary(type) do
    {false, "unsupported_check_type", %{"check_type" => type}}
  end

  defp do_evaluate_check(_check, _output_text), do: {false, "malformed_check", %{}}

  defp aggregate(case_id, check_results) do
    total_checks = length(check_results)
    passed_checks = Enum.count(check_results, fn result -> result["passed"] end)

    if total_checks == 0 do
      %{
        "case_id" => case_id,
        "status" => "not_applicable",
        "total_checks" => 0,
        "passed_checks" => 0,
        "pass_rate" => nil,
        "all_passed" => nil,
        "checks" => []
      }
    else
      %{
        "case_id" => case_id,
        "status" => "evaluated",
        "total_checks" => total_checks,
        "passed_checks" => passed_checks,
        "pass_rate" => passed_checks / total_checks,
        "all_passed" => passed_checks == total_checks,
        "checks" => check_results
      }
    end
  end

  defp base_result(check, index, passed, reason) do
    %{
      "check_index" => index,
      "check_id" => Map.get(check, "id"),
      "type" => Map.get(check, "type", "unknown"),
      "passed" => passed,
      "reason" => reason
    }
  end

  defp decode_json_object(output_text) do
    with {:ok, json} <- extract_json(output_text),
         {:ok, decoded} <- Jason.decode(json) do
      if is_map(decoded), do: {:ok, decoded}, else: {:error, :json_not_object}
    else
      {:error, :invalid_json_fence} -> {:error, :invalid_json_fence}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  defp extract_json(output_text) do
    trimmed = String.trim(output_text)

    if String.starts_with?(trimmed, "```") do
      case Regex.named_captures(@json_fence, trimmed) do
        %{"body" => body} -> {:ok, String.trim(body)}
        nil -> {:error, :invalid_json_fence}
      end
    else
      {:ok, trimmed}
    end
  end

  defp compare_json(actual, expected, allow_extra_keys, numeric_comparison, path)

  defp compare_json(actual, expected, allow_extra_keys, numeric_comparison, path)
       when is_map(actual) and is_map(expected) do
    actual_keys = actual |> Map.keys() |> Enum.sort()
    expected_keys = expected |> Map.keys() |> Enum.sort()
    missing_keys = expected_keys -- actual_keys
    extra_keys = if allow_extra_keys, do: [], else: actual_keys -- expected_keys
    common_keys = expected_keys -- missing_keys

    missing_mismatches =
      Enum.map(missing_keys, fn key ->
        mismatch(path ++ [key], "missing_key", Map.fetch!(expected, key), nil)
      end)

    extra_mismatches =
      Enum.map(extra_keys, fn key ->
        mismatch(path ++ [key], "extra_key", nil, Map.fetch!(actual, key))
      end)

    nested_mismatches =
      Enum.flat_map(common_keys, fn key ->
        compare_json(
          Map.fetch!(actual, key),
          Map.fetch!(expected, key),
          allow_extra_keys,
          numeric_comparison,
          path ++ [key]
        )
      end)

    missing_mismatches ++ extra_mismatches ++ nested_mismatches
  end

  defp compare_json(actual, expected, allow_extra_keys, numeric_comparison, path)
       when is_list(actual) and is_list(expected) do
    if length(actual) == length(expected) do
      actual
      |> Enum.zip(expected)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{actual_item, expected_item}, index} ->
        compare_json(
          actual_item,
          expected_item,
          allow_extra_keys,
          numeric_comparison,
          path ++ [index]
        )
      end)
    else
      [mismatch(path, "array_length_mismatch", expected, actual)]
    end
  end

  defp compare_json(actual, expected, _allow_extra_keys, "mathematical", _path)
       when is_number(actual) and is_number(expected) and actual == expected,
       do: []

  defp compare_json(actual, expected, _allow_extra_keys, _numeric_comparison, _path)
       when actual === expected,
       do: []

  defp compare_json(actual, expected, _allow_extra_keys, _numeric_comparison, path) do
    [mismatch(path, "value_mismatch", expected, actual)]
  end

  defp mismatch(path, reason, expected, actual) do
    %{
      "path" => format_path(path),
      "reason" => reason,
      "expected" => expected,
      "actual" => actual
    }
  end

  defp format_path(path) do
    Enum.reduce(path, "$", fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, acc -> "#{acc}.#{key}"
    end)
  end

  defp contains_fact?(output_text, fact) do
    normalized_output = " #{normalize_fact(output_text)} "
    normalized_fact = normalize_fact(fact)

    normalized_fact != "" and String.contains?(normalized_output, " #{normalized_fact} ")
  end

  defp valid_phrases?(phrases) do
    phrases != [] and Enum.all?(phrases, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp compile_patterns(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, compiled} ->
      case Regex.compile(pattern, "iu") do
        {:ok, regex} -> {:cont, {:ok, [{pattern, regex} | compiled]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
