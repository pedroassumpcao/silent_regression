defmodule SilentRegression.CaseExpectations do
  @moduledoc """
  Bounded, deterministic expectations for one immutable representative case.

  Shared contracts describe invariants for every case. This module describes the exact outcome
  expected for one case without allowing executable predicates, regular expressions, or semantic
  scoring.
  """

  alias SilentRegression.Contracts.{Citations, Evidence, JsonPointer, Limits, StrictJson, Text}
  alias SilentRegression.Monitors.{Fingerprint, JsonValue}

  @none_schema "no_case_expectation"
  @schema_version "case_expectation_v1"
  @fingerprint_schema "case-expectation-fingerprint-v1"
  @check_types ~w(label json_value json_number source_ids abstention)
  @numeric_comparisons ~w(strict mathematical)
  @max_checks 20
  @max_expectation_bytes 40_000
  @check_id_pattern ~r/^[a-z][a-z0-9_-]{0,79}$/
  @source_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/

  @type status :: :not_configured | :pass | :fail | :evaluator_error

  @spec none_schema() :: String.t()
  def none_schema, do: @none_schema

  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @spec check_types() :: [String.t()]
  def check_types, do: @check_types

  @spec max_checks() :: pos_integer()
  def max_checks, do: @max_checks

  @spec max_expectation_bytes() :: pos_integer()
  def max_expectation_bytes, do: @max_expectation_bytes

  @spec normalize(String.t() | nil, map() | nil) :: {:ok, map()} | {:error, map()}
  def normalize(schema_version, expectation)

  def normalize(schema_version, expectation)
      when schema_version in [nil, @none_schema] and expectation in [nil, %{}] do
    normalized(@none_schema, %{})
  end

  def normalize(schema_version, expectation)
      when schema_version in [nil, @schema_version] and is_map(expectation) do
    with {:ok, expectation} <- JsonValue.normalize(expectation),
         :ok <- validate_expectation_size(expectation),
         {:ok, checks} <- validate_root(expectation) do
      normalized(@schema_version, %{"checks" => checks})
    else
      {:error, error} -> {:error, error}
      _reason -> invalid("invalid_expectation", "Case expectation is invalid.")
    end
  end

  def normalize(_schema_version, _expectation) do
    invalid("invalid_expectation_schema", "Case expectation schema or payload is invalid.")
  end

  @spec evaluate(String.t(), map(), String.t(), binary()) :: map()
  def evaluate(schema_version, expectation, fingerprint, output)
      when is_binary(schema_version) and is_map(expectation) and is_binary(fingerprint) and
             is_binary(output) do
    with {:ok, normalized} <- normalize(schema_version, expectation),
         true <- normalized.fingerprint == fingerprint do
      evaluate_normalized(normalized, output)
    else
      false -> evaluator_error(schema_version, fingerprint, "expectation_fingerprint_mismatch")
      {:error, error} -> evaluator_error(schema_version, fingerprint, error.code)
    end
  rescue
    _error -> evaluator_error(schema_version, fingerprint, "unexpected_expectation_error")
  end

  def evaluate(schema_version, _expectation, fingerprint, _output) do
    evaluator_error(schema_version, fingerprint, "invalid_expectation_input")
  end

  defp normalized(schema_version, expectation) do
    {:ok,
     %{
       schema_version: schema_version,
       expectation: expectation,
       fingerprint:
         Fingerprint.digest(%{
           "fingerprint_schema" => @fingerprint_schema,
           "expectation_schema_version" => schema_version,
           "expectation" => expectation
         })
     }}
  end

  defp validate_expectation_size(expectation) do
    case JsonValue.encoded_size(expectation) do
      {:ok, size} when size <= @max_expectation_bytes -> :ok
      _result -> invalid("expectation_too_large", "Case expectation exceeds the byte limit.")
    end
  end

  defp validate_root(%{"checks" => checks} = expectation)
       when map_size(expectation) == 1 and is_list(checks) and checks != [] and
              length(checks) <= @max_checks do
    with {:ok, checks} <- validate_checks(checks),
         :ok <- validate_unique_check_ids(checks) do
      {:ok, checks}
    end
  end

  defp validate_root(_expectation) do
    invalid(
      "invalid_expectation_root",
      "Configured case expectation must contain only a non-empty bounded checks array."
    )
  end

  defp validate_checks(checks) do
    checks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {check, index}, {:ok, normalized} ->
      case validate_check(check) do
        {:ok, check} -> {:cont, {:ok, [check | normalized]}}
        {:error, error} -> {:halt, {:error, Map.put(error, :check_index, index)}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_check(%{"id" => id, "type" => "label", "allowed_values" => values} = check)
       when map_size(check) == 3 do
    with :ok <- validate_check_id(id),
         {:ok, values} <- validate_alternatives(values) do
      {:ok, %{"id" => id, "type" => "label", "allowed_values" => values}}
    end
  end

  defp validate_check(
         %{
           "id" => id,
           "type" => "json_value",
           "path" => path,
           "allowed_values" => values,
           "numeric_comparison" => numeric_comparison
         } = check
       )
       when map_size(check) == 5 do
    with :ok <- validate_check_id(id),
         :ok <- validate_pointer(path),
         {:ok, values} <- validate_json_alternatives(values),
         true <- numeric_comparison in @numeric_comparisons do
      {:ok,
       %{
         "id" => id,
         "type" => "json_value",
         "path" => path,
         "allowed_values" => values,
         "numeric_comparison" => numeric_comparison
       }}
    else
      false -> invalid("invalid_numeric_comparison", "Numeric comparison is unsupported.")
      {:error, error} -> {:error, error}
    end
  end

  defp validate_check(
         %{
           "id" => id,
           "type" => "json_number",
           "path" => path,
           "target" => target,
           "tolerance" => tolerance
         } = check
       )
       when map_size(check) == 5 do
    with :ok <- validate_check_id(id),
         :ok <- validate_pointer(path),
         :ok <- validate_number(target),
         :ok <- validate_tolerance(tolerance) do
      {:ok,
       %{
         "id" => id,
         "type" => "json_number",
         "path" => path,
         "target" => target,
         "tolerance" => tolerance
       }}
    end
  end

  defp validate_check(
         %{
           "id" => id,
           "type" => "source_ids",
           "required" => required,
           "allowed" => allowed,
           "require_at_least_one" => require_at_least_one
         } = check
       )
       when map_size(check) == 5 do
    with :ok <- validate_check_id(id),
         {:ok, required} <- validate_source_ids(required, true),
         {:ok, allowed} <- validate_source_ids(allowed, false),
         true <- Enum.all?(required, &(&1 in allowed)),
         true <- is_boolean(require_at_least_one) do
      {:ok,
       %{
         "id" => id,
         "type" => "source_ids",
         "required" => required,
         "allowed" => allowed,
         "require_at_least_one" => require_at_least_one
       }}
    else
      false ->
        invalid("invalid_source_ids", "Required sources must be allowed and options valid.")

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_check(
         %{
           "id" => id,
           "type" => "abstention",
           "expected" => expected,
           "alternatives" => alternatives
         } = check
       )
       when map_size(check) == 4 do
    with :ok <- validate_check_id(id),
         true <- is_boolean(expected),
         {:ok, alternatives} <- validate_alternatives(alternatives) do
      {:ok,
       %{
         "id" => id,
         "type" => "abstention",
         "expected" => expected,
         "alternatives" => alternatives
       }}
    else
      false -> invalid("invalid_abstention", "Abstention expectation must be a boolean.")
      {:error, error} -> {:error, error}
    end
  end

  defp validate_check(%{"type" => type}) when type not in @check_types do
    invalid("unsupported_check_type", "Case expectation check type is unsupported.")
  end

  defp validate_check(_check) do
    invalid("invalid_check", "Case expectation check fields are invalid.")
  end

  defp validate_check_id(id) when is_binary(id) do
    if Regex.match?(@check_id_pattern, id),
      do: :ok,
      else: invalid("invalid_check_id", "Check ID is invalid.")
  end

  defp validate_check_id(_id), do: invalid("invalid_check_id", "Check ID is invalid.")

  defp validate_pointer(path) when is_binary(path) do
    case JsonPointer.parse(path) do
      {:ok, _tokens} -> :ok
      {:error, _reason} -> invalid("invalid_json_pointer", "JSON Pointer is invalid.")
    end
  end

  defp validate_pointer(_path), do: invalid("invalid_json_pointer", "JSON Pointer is invalid.")

  defp validate_alternatives(values) when is_list(values) do
    valid? =
      values != [] and length(values) <= Limits.alternatives() and
        Enum.all?(values, fn value ->
          is_binary(value) and String.valid?(value) and String.trim(value) != "" and
            byte_size(value) <= Limits.alternative_bytes()
        end)

    normalized_values = Enum.map(values, &Text.normalize/1)

    if valid? and Enum.uniq(normalized_values) == normalized_values,
      do: {:ok, values},
      else: invalid("invalid_alternatives", "Alternatives must be unique bounded strings.")
  end

  defp validate_alternatives(_values) do
    invalid("invalid_alternatives", "Alternatives must be a non-empty bounded array.")
  end

  defp validate_json_alternatives(values) when is_list(values) do
    fingerprints = Enum.map(values, &Fingerprint.digest/1)

    if values != [] and length(values) <= Limits.alternatives() and
         Enum.uniq(fingerprints) == fingerprints,
       do: {:ok, values},
       else: invalid("duplicate_json_alternative", "JSON alternatives must be unique.")
  end

  defp validate_json_alternatives(_values) do
    invalid("invalid_json_alternatives", "JSON alternatives must be a non-empty bounded array.")
  end

  defp validate_number(value) when is_number(value) do
    if abs(value) <= Limits.max_numeric_magnitude(),
      do: :ok,
      else: invalid("number_out_of_range", "Numeric expectation exceeds the safe range.")
  end

  defp validate_number(_value), do: invalid("invalid_number", "Numeric expectation is invalid.")

  defp validate_tolerance(value) when is_number(value) and value >= 0, do: validate_number(value)

  defp validate_tolerance(_value) do
    invalid("invalid_tolerance", "Numeric tolerance must be non-negative.")
  end

  defp validate_source_ids(values, allow_empty?) when is_list(values) do
    valid_count? = length(values) <= Limits.alternatives() and (allow_empty? or values != [])
    valid_values? = Enum.all?(values, &(is_binary(&1) and Regex.match?(@source_id_pattern, &1)))

    if valid_count? and valid_values? and Enum.uniq(values) == values,
      do: {:ok, values},
      else: invalid("invalid_source_ids", "Source IDs must be unique bounded identifiers.")
  end

  defp validate_source_ids(_values, _allow_empty?) do
    invalid("invalid_source_ids", "Source IDs must be an array.")
  end

  defp validate_unique_check_ids(checks) do
    ids = Enum.map(checks, & &1["id"])

    if Enum.uniq(ids) == ids,
      do: :ok,
      else: invalid("duplicate_check_id", "Check IDs must be unique within a case.")
  end

  defp evaluate_normalized(%{schema_version: @none_schema} = normalized, _output) do
    evaluation(normalized, :not_configured, [], nil)
  end

  defp evaluate_normalized(normalized, output) do
    cond do
      not String.valid?(output) ->
        evaluator_error(normalized, "invalid_output_utf8")

      byte_size(output) > Limits.output_bytes() ->
        evaluator_error(normalized, "output_too_large")

      true ->
        context = %{
          output: output,
          normalized_output: Text.normalize(output),
          json: StrictJson.decode(output),
          citations: Citations.extract(output)
        }

        results = Enum.map(normalized.expectation["checks"], &evaluate_check(&1, context))
        status = aggregate_status(results)
        error = if status == :evaluator_error, do: error("check_evaluator_error")
        evaluation(normalized, status, results, error)
    end
  end

  defp evaluate_check(%{"type" => "label"} = check, context) do
    matched =
      Enum.find(check["allowed_values"], &(Text.normalize(&1) == context.normalized_output))

    evidence = %{
      "normalized_output" => Evidence.text(context.normalized_output),
      "allowed_values" => Evidence.list(check["allowed_values"]),
      "matched_value" => matched
    }

    if matched,
      do:
        result(
          check,
          :pass,
          "expected_label_matched",
          "The case-specific label matched.",
          evidence
        ),
      else:
        result(
          check,
          :fail,
          "expected_label_mismatch",
          "The case-specific label did not match.",
          evidence
        )
  end

  defp evaluate_check(%{"type" => "json_value"} = check, context) do
    case fetch_json_value(check, context) do
      {:ok, actual} ->
        matched =
          Enum.find(
            check["allowed_values"],
            &json_equal?(actual, &1, check["numeric_comparison"])
          )

        evidence = %{
          "path" => Evidence.text(check["path"]),
          "actual" => Evidence.value(actual),
          "allowed_values" => Evidence.list(Enum.map(check["allowed_values"], &Evidence.value/1)),
          "numeric_comparison" => check["numeric_comparison"],
          "matched_value" => if(is_nil(matched), do: nil, else: Evidence.value(matched))
        }

        if is_nil(matched),
          do:
            result(
              check,
              :fail,
              "expected_json_value_mismatch",
              "The case-specific JSON value did not match.",
              evidence
            ),
          else:
            result(
              check,
              :pass,
              "expected_json_value_matched",
              "The case-specific JSON value matched.",
              evidence
            )

      {:error, code, evidence} ->
        result(
          check,
          :fail,
          code,
          "The case-specific JSON value could not be resolved.",
          evidence
        )
    end
  end

  defp evaluate_check(%{"type" => "json_number"} = check, context) do
    case fetch_json_value(check, context) do
      {:ok, actual} when is_number(actual) ->
        difference = abs(actual - check["target"])
        passed = within_tolerance?(actual, check["target"], check["tolerance"])

        evidence = %{
          "path" => Evidence.text(check["path"]),
          "actual" => actual,
          "target" => check["target"],
          "tolerance" => check["tolerance"],
          "absolute_difference" => difference
        }

        if passed,
          do:
            result(
              check,
              :pass,
              "expected_number_within_tolerance",
              "The case-specific number is within tolerance.",
              evidence
            ),
          else:
            result(
              check,
              :fail,
              "expected_number_outside_tolerance",
              "The case-specific number is outside tolerance.",
              evidence
            )

      {:ok, actual} ->
        result(
          check,
          :fail,
          "expected_number_type_mismatch",
          "The case-specific JSON value is not numeric.",
          %{
            "path" => Evidence.text(check["path"]),
            "actual_type" => Evidence.json_type(actual)
          }
        )

      {:error, code, evidence} ->
        result(
          check,
          :fail,
          code,
          "The case-specific numeric value could not be resolved.",
          evidence
        )
    end
  end

  defp evaluate_check(%{"type" => "source_ids"} = check, context) do
    found = Citations.ids(context.citations)
    missing = Enum.reject(check["required"], &(&1 in found))
    disallowed = Enum.reject(found, &(&1 in check["allowed"]))

    evidence = %{
      "found_source_ids" => Evidence.list(found),
      "required_source_ids" => Evidence.list(check["required"]),
      "allowed_source_ids" => Evidence.list(check["allowed"]),
      "missing_source_ids" => Evidence.list(missing),
      "disallowed_source_ids" => Evidence.list(disallowed),
      "require_at_least_one" => check["require_at_least_one"]
    }

    cond do
      missing != [] ->
        result(
          check,
          :fail,
          "expected_source_missing",
          "A required case-specific source ID is missing.",
          evidence
        )

      disallowed != [] ->
        result(
          check,
          :fail,
          "unexpected_source_present",
          "A source ID outside the case-specific set is present.",
          evidence
        )

      check["require_at_least_one"] and found == [] ->
        result(
          check,
          :fail,
          "expected_source_absent",
          "At least one case-specific source ID is required.",
          evidence
        )

      true ->
        result(
          check,
          :pass,
          "expected_sources_matched",
          "The case-specific source IDs matched.",
          evidence
        )
    end
  end

  defp evaluate_check(%{"type" => "abstention"} = check, context) do
    matched =
      Enum.find(
        check["alternatives"],
        &Text.contains_normalized_literal?(context.normalized_output, &1)
      )

    abstained? = not is_nil(matched)
    passed = abstained? == check["expected"]

    evidence = %{
      "expected_abstention" => check["expected"],
      "abstention_detected" => abstained?,
      "matched_alternative" => if(is_nil(matched), do: nil, else: Evidence.text(matched))
    }

    if passed,
      do:
        result(
          check,
          :pass,
          "expected_abstention_matched",
          "The case-specific abstention expectation matched.",
          evidence
        ),
      else:
        result(
          check,
          :fail,
          "expected_abstention_mismatch",
          "The case-specific abstention expectation did not match.",
          evidence
        )
  end

  defp evaluate_check(check, _context) do
    result(
      check,
      :evaluator_error,
      "unexpected_check_type",
      "The validated case-specific check type is unavailable.",
      %{}
    )
  end

  defp fetch_json_value(check, context) do
    with {:ok, document} <- context.json,
         {:ok, tokens} <- JsonPointer.parse(check["path"]),
         {:ok, value} <- JsonPointer.fetch(document, tokens) do
      {:ok, value}
    else
      {:error, :nesting_too_deep} ->
        {:error, "expectation_json_nesting_too_deep", path_evidence(check)}

      {:error, reason} when reason in [:invalid_json, :duplicate_object_key, :invalid_utf8] ->
        {:error, "expectation_#{reason}", path_evidence(check)}

      {:error, reason} when reason in [:missing, :invalid_array_index, :wrong_container_type] ->
        {:error, "expectation_json_path_#{reason}", path_evidence(check)}

      {:error, _reason} ->
        {:error, "invalid_internal_expectation_pointer", path_evidence(check)}
    end
  end

  defp path_evidence(check), do: %{"path" => Evidence.text(check["path"])}

  defp aggregate_status(results) do
    cond do
      Enum.any?(results, &(&1.status == :evaluator_error)) -> :evaluator_error
      Enum.any?(results, &(&1.status == :fail)) -> :fail
      true -> :pass
    end
  end

  defp evaluation(normalized, status, results, error) do
    %{
      schema_version: normalized.schema_version,
      fingerprint: normalized.fingerprint,
      status: status,
      results: results,
      error: error
    }
  end

  defp evaluator_error(
         %{schema_version: schema_version, fingerprint: fingerprint} = normalized,
         code
       ) do
    evaluation(normalized, :evaluator_error, [], error(code))
    |> Map.put(:schema_version, schema_version)
    |> Map.put(:fingerprint, fingerprint)
  end

  defp evaluator_error(schema_version, fingerprint, code) do
    %{
      schema_version: schema_version,
      fingerprint: fingerprint,
      status: :evaluator_error,
      results: [],
      error: error(code)
    }
  end

  defp result(check, status, code, explanation, evidence) do
    %{
      check_id: check["id"],
      check_type: check["type"],
      status: status,
      code: code,
      explanation: explanation,
      evidence: evidence
    }
  rescue
    _error ->
      %{
        check_id: Map.get(check, "id", "unknown"),
        check_type: Map.get(check, "type", "unknown"),
        status: :evaluator_error,
        code: "unexpected_check_error",
        explanation: "The case-specific check could not be evaluated safely.",
        evidence: %{}
      }
  end

  defp json_equal?(actual, expected, "strict"), do: actual === expected

  defp json_equal?(actual, expected, "mathematical")
       when is_number(actual) and is_number(expected),
       do: actual == expected

  defp json_equal?(actual, expected, "mathematical")
       when is_map(actual) and is_map(expected) do
    Map.keys(actual) |> Enum.sort() == Map.keys(expected) |> Enum.sort() and
      Enum.all?(expected, fn {key, value} ->
        Map.has_key?(actual, key) and json_equal?(actual[key], value, "mathematical")
      end)
  end

  defp json_equal?(actual, expected, "mathematical")
       when is_list(actual) and is_list(expected) do
    length(actual) == length(expected) and
      actual
      |> Enum.zip(expected)
      |> Enum.all?(fn {actual, expected} -> json_equal?(actual, expected, "mathematical") end)
  end

  defp json_equal?(actual, expected, "mathematical"), do: actual === expected

  defp within_tolerance?(actual, target, tolerance) do
    difference = actual |> decimal() |> Decimal.sub(decimal(target)) |> Decimal.abs()
    Decimal.compare(difference, decimal(tolerance)) in [:lt, :eq]
  end

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp error(code) do
    %{
      "code" => code,
      "message" => "The case-specific expectation could not be evaluated safely."
    }
  end

  defp invalid(code, message), do: {:error, %{code: code, message: message}}
end
