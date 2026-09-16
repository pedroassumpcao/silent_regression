defmodule SilentRegression.Contracts.Parser do
  @moduledoc """
  Strict parser for deterministic contract schema version 1.

  Customer-controlled strings are dispatched only against fixed values. The
  parser never creates atoms from input.
  """

  alias SilentRegression.Contracts.{Contract, JsonPointer, Limits, StrictJson, Text}

  @rule_id ~r/\A[a-z][a-z0-9_-]{0,79}\z/
  @source_id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/
  @identity ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,99}\z/
  @rule_types ~w(
    all
    any
    not
    json_valid
    json_path_exists
    json_path_type
    json_path_equals
    json_path_allowed_values
    json_path_number
    classification
    required_text
    forbidden_text
    required_source_ids
    allowed_source_ids
    fact_citation
    required_abstention
    length
  )
  @json_types ~w(object array string number integer boolean null)
  @numeric_comparisons ~w(strict mathematical)
  @length_units ~w(graphemes words)
  @severities ~w(critical warning)

  @spec rule_types() :: [String.t()]
  def rule_types, do: @rule_types

  @spec parse_json(String.t()) :: {:ok, Contract.t()} | {:error, map()}
  def parse_json(encoded) when is_binary(encoded) do
    cond do
      byte_size(encoded) > Limits.contract_bytes() ->
        error("", "contract_too_large", "Contract exceeds the version-1 byte limit")

      true ->
        case StrictJson.decode(encoded) do
          {:ok, decoded} ->
            parse(decoded)

          {:error, :invalid_utf8} ->
            error("", "invalid_utf8", "Contract must be valid UTF-8")

          {:error, :duplicate_object_key} ->
            error("", "duplicate_object_key", "Contract JSON contains a duplicate object key")

          {:error, :nesting_too_deep} ->
            error("", "json_nesting_too_deep", "Contract JSON exceeds the nesting limit")

          {:error, :invalid_json} ->
            error("", "invalid_json", "Contract is not valid JSON")
        end
    end
  end

  def parse_json(_encoded), do: error("", "invalid_type", "Contract JSON must be a string")

  @spec parse(map()) :: {:ok, Contract.t()} | {:error, map()}
  def parse(attributes) when is_map(attributes) do
    with :ok <- validate_json_value(attributes, ""),
         :ok <- validate_encoded_size(attributes),
         :ok <-
           validate_keys(
             attributes,
             ~w(schema_version contract_id contract_version monitor_id root),
             [],
             ""
           ),
         :ok <- validate_schema_version(attributes["schema_version"]),
         :ok <- validate_identity(attributes, "contract_id"),
         :ok <- validate_contract_version(attributes["contract_version"]),
         :ok <- validate_identity(attributes, "monitor_id"),
         {:ok, root, _state} <-
           validate_rule(attributes["root"], "/root", 1, %{ids: MapSet.new(), count: 0}) do
      {:ok,
       Contract.build(
         attributes["schema_version"],
         attributes["contract_id"],
         attributes["contract_version"],
         attributes["monitor_id"],
         root
       )}
    end
  end

  def parse(_attributes), do: error("", "invalid_type", "Contract must be an object")

  defp validate_encoded_size(attributes) do
    case Jason.encode(attributes, maps: :strict) do
      {:ok, encoded} ->
        if byte_size(encoded) <= Limits.contract_bytes(),
          do: :ok,
          else: error("", "contract_too_large", "Contract exceeds the version-1 byte limit")

      {:error, _reason} ->
        error("", "invalid_json_value", "Contract must contain only JSON values")
    end
  end

  defp validate_schema_version(1), do: :ok

  defp validate_schema_version(_version) do
    error(
      "/schema_version",
      "unsupported_schema_version",
      "Only contract schema version 1 is supported"
    )
  end

  defp validate_identity(attributes, field) do
    value = attributes[field]

    if is_binary(value) and Regex.match?(@identity, value) do
      :ok
    else
      error(
        "/#{field}",
        "invalid_identity",
        "#{field} must be a non-empty string of at most 100 bytes"
      )
    end
  end

  defp validate_contract_version(version) when is_integer(version) and version > 0, do: :ok

  defp validate_contract_version(_version) do
    error("/contract_version", "invalid_version", "contract_version must be a positive integer")
  end

  defp validate_rule(rule, path, depth, state) when is_map(rule) do
    with :ok <- validate_depth(depth, path),
         :ok <-
           validate_keys(
             rule,
             ~w(id type),
             ["severity" | rule_optional_fields(rule["type"])],
             path
           ),
         :ok <- validate_rule_id(rule["id"], path <> "/id"),
         :ok <- validate_rule_type(rule["type"], path <> "/type"),
         :ok <- validate_rule_severity(rule, path <> "/severity"),
         {:ok, state} <- register_rule(rule["id"], path, state),
         {:ok, normalized, state} <- validate_rule_body(rule, path, depth, state) do
      {:ok, normalized, state}
    end
  end

  defp validate_rule(_rule, path, _depth, _state) do
    error(path, "invalid_type", "Rule must be an object")
  end

  defp validate_depth(depth, path) do
    if depth <= Limits.rule_depth(),
      do: :ok,
      else: error(path, "rule_depth_exceeded", "Rule nesting exceeds the version-1 limit")
  end

  defp validate_rule_id(id, path) when is_binary(id) do
    if String.length(id) <= Limits.rule_id_characters() and Regex.match?(@rule_id, id),
      do: :ok,
      else:
        error(
          path,
          "invalid_rule_id",
          "Rule ID must start with a lowercase letter and use only lowercase letters, numbers, underscores, or hyphens"
        )
  end

  defp validate_rule_id(_id, path), do: error(path, "invalid_rule_id", "Rule ID must be a string")

  defp validate_rule_type(type, _path) when type in @rule_types, do: :ok

  defp validate_rule_type(_type, path) do
    error(
      path,
      "unsupported_rule_type",
      "Rule type is not supported by contract schema version 1"
    )
  end

  defp validate_rule_severity(rule, path) do
    case Map.fetch(rule, "severity") do
      :error -> :ok
      {:ok, severity} -> validate_enum(severity, @severities, path)
    end
  end

  defp register_rule(id, path, state) do
    cond do
      MapSet.member?(state.ids, id) ->
        error(path <> "/id", "duplicate_rule_id", "Rule IDs must be unique within a contract")

      state.count >= Limits.rule_nodes() ->
        error(path, "rule_count_exceeded", "Contract contains too many rule nodes")

      true ->
        {:ok, %{state | ids: MapSet.put(state.ids, id), count: state.count + 1}}
    end
  end

  defp rule_optional_fields(type) when type in ["all", "any"], do: ["rules"]
  defp rule_optional_fields("not"), do: ["rule"]
  defp rule_optional_fields("json_valid"), do: []
  defp rule_optional_fields(type) when type in ["json_path_exists"], do: ["path"]
  defp rule_optional_fields("json_path_type"), do: ~w(path expected_type)
  defp rule_optional_fields("json_path_equals"), do: ~w(path expected numeric_comparison)

  defp rule_optional_fields("json_path_allowed_values"),
    do: ~w(path allowed_values numeric_comparison)

  defp rule_optional_fields("json_path_number"),
    do: ~w(path minimum maximum target tolerance)

  defp rule_optional_fields("classification"), do: ["allowed_values"]

  defp rule_optional_fields(type) when type in ["required_text", "forbidden_text"],
    do: ["alternatives"]

  defp rule_optional_fields("required_source_ids"), do: ["source_ids"]
  defp rule_optional_fields("allowed_source_ids"), do: ~w(source_ids require_at_least_one)

  defp rule_optional_fields("fact_citation"),
    do: ~w(fact_alternatives source_ids max_distance_characters)

  defp rule_optional_fields("required_abstention"), do: ["alternatives"]
  defp rule_optional_fields("length"), do: ~w(unit minimum maximum)
  defp rule_optional_fields(_type), do: []

  defp validate_rule_body(%{"type" => type} = rule, path, depth, state)
       when type in ["all", "any"] do
    with :ok <- validate_required_fields(rule, ["rules"], path),
         :ok <- validate_group(rule["rules"], path <> "/rules") do
      rule["rules"]
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], state}, fn {child, index}, {:ok, children, state} ->
        case validate_rule(child, "#{path}/rules/#{index}", depth + 1, state) do
          {:ok, child, state} -> {:cont, {:ok, [child | children], state}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> then(fn
        {:ok, children, state} -> {:ok, %{rule | "rules" => Enum.reverse(children)}, state}
        {:error, error} -> {:error, error}
      end)
    end
  end

  defp validate_rule_body(%{"type" => "not"} = rule, path, depth, state) do
    with :ok <- validate_required_fields(rule, ["rule"], path),
         {:ok, child, state} <- validate_rule(rule["rule"], path <> "/rule", depth + 1, state) do
      {:ok, %{rule | "rule" => child}, state}
    end
  end

  defp validate_rule_body(%{"type" => "json_valid"} = rule, _path, _depth, state),
    do: {:ok, rule, state}

  defp validate_rule_body(%{"type" => "json_path_exists"} = rule, path, _depth, state) do
    validate_path_rule(rule, path, ["path"], state)
  end

  defp validate_rule_body(%{"type" => "json_path_type"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ~w(path expected_type), path),
         :ok <- validate_pointer(rule["path"], path <> "/path"),
         :ok <- validate_enum(rule["expected_type"], @json_types, path <> "/expected_type") do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "json_path_equals"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ~w(path expected numeric_comparison), path),
         :ok <- validate_pointer(rule["path"], path <> "/path"),
         :ok <-
           validate_enum(
             rule["numeric_comparison"],
             @numeric_comparisons,
             path <> "/numeric_comparison"
           ) do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(
         %{"type" => "json_path_allowed_values"} = rule,
         path,
         _depth,
         state
       ) do
    with :ok <- validate_required_fields(rule, ~w(path allowed_values numeric_comparison), path),
         :ok <- validate_pointer(rule["path"], path <> "/path"),
         :ok <- validate_json_values(rule["allowed_values"], path <> "/allowed_values"),
         :ok <-
           validate_enum(
             rule["numeric_comparison"],
             @numeric_comparisons,
             path <> "/numeric_comparison"
           ) do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "json_path_number"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ["path"], path),
         :ok <- validate_pointer(rule["path"], path <> "/path"),
         :ok <- validate_numeric_bounds(rule, path) do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "classification"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ["allowed_values"], path),
         :ok <- validate_alternatives(rule["allowed_values"], path <> "/allowed_values") do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => type} = rule, path, _depth, state)
       when type in ["required_text", "forbidden_text", "required_abstention"] do
    with :ok <- validate_required_fields(rule, ["alternatives"], path),
         :ok <- validate_alternatives(rule["alternatives"], path <> "/alternatives") do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "required_source_ids"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ["source_ids"], path),
         :ok <- validate_source_ids(rule["source_ids"], path <> "/source_ids") do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "allowed_source_ids"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ~w(source_ids require_at_least_one), path),
         :ok <- validate_source_ids(rule["source_ids"], path <> "/source_ids"),
         :ok <- validate_boolean(rule["require_at_least_one"], path <> "/require_at_least_one") do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "fact_citation"} = rule, path, _depth, state) do
    with :ok <-
           validate_required_fields(
             rule,
             ~w(fact_alternatives source_ids max_distance_characters),
             path
           ),
         :ok <- validate_alternatives(rule["fact_alternatives"], path <> "/fact_alternatives"),
         :ok <- validate_source_ids(rule["source_ids"], path <> "/source_ids"),
         :ok <-
           validate_distance(rule["max_distance_characters"], path <> "/max_distance_characters") do
      {:ok, rule, state}
    end
  end

  defp validate_rule_body(%{"type" => "length"} = rule, path, _depth, state) do
    with :ok <- validate_required_fields(rule, ["unit"], path),
         :ok <- validate_enum(rule["unit"], @length_units, path <> "/unit"),
         :ok <- validate_length_bounds(rule, path) do
      {:ok, rule, state}
    end
  end

  defp validate_path_rule(rule, path, required, state) do
    with :ok <- validate_required_fields(rule, required, path),
         :ok <- validate_pointer(rule["path"], path <> "/path") do
      {:ok, rule, state}
    end
  end

  defp validate_group(rules, path) when is_list(rules) do
    if rules != [] and length(rules) <= Limits.group_children(),
      do: :ok,
      else:
        error(
          path,
          "invalid_group",
          "A group must contain between 1 and #{Limits.group_children()} rules"
        )
  end

  defp validate_group(_rules, path) do
    error(
      path,
      "invalid_group",
      "A group must contain between 1 and #{Limits.group_children()} rules"
    )
  end

  defp validate_pointer(pointer, path) do
    case JsonPointer.parse(pointer) do
      {:ok, _tokens} -> :ok
      {:error, reason} -> error(path, "invalid_json_pointer", "Invalid JSON Pointer: #{reason}")
    end
  end

  defp validate_json_values(values, path) when is_list(values) do
    cond do
      values == [] or length(values) > Limits.alternatives() ->
        error(
          path,
          "invalid_allowed_values",
          "Allowed values must be a non-empty unique bounded list"
        )

      length(Enum.uniq(values)) != length(values) ->
        error(path, "duplicate_allowed_value", "Allowed values must be unique")

      true ->
        :ok
    end
  end

  defp validate_json_values(_values, path) do
    error(
      path,
      "invalid_allowed_values",
      "Allowed values must be a non-empty unique bounded list"
    )
  end

  defp validate_alternatives(values, path) when is_list(values) do
    if values != [] and length(values) <= Limits.alternatives() do
      normalized = Enum.map(values, &normalize_alternative/1)

      cond do
        Enum.any?(normalized, &is_nil/1) ->
          error(
            path,
            "invalid_alternative",
            "Alternatives must be non-empty UTF-8 strings within the byte limit"
          )

        Enum.uniq(normalized) != normalized ->
          error(
            path,
            "duplicate_alternative",
            "Alternatives must be unique after version-1 normalization"
          )

        true ->
          :ok
      end
    else
      error(path, "invalid_alternatives", "Alternatives must be a non-empty bounded list")
    end
  end

  defp validate_alternatives(_values, path) do
    error(path, "invalid_alternatives", "Alternatives must be a non-empty bounded list")
  end

  defp normalize_alternative(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= Limits.alternative_bytes() and
         Text.normalize(value) != "",
       do: Text.normalize(value),
       else: nil
  end

  defp normalize_alternative(_value), do: nil

  defp validate_source_ids(values, path) when is_list(values) do
    if values != [] and length(values) <= Limits.alternatives() do
      cond do
        Enum.any?(values, &(not valid_source_id?(&1))) ->
          error(
            path,
            "invalid_source_id",
            "Source IDs must use the documented bracketed-ID character set"
          )

        Enum.uniq(values) != values ->
          error(path, "duplicate_source_id", "Source IDs must be unique")

        true ->
          :ok
      end
    else
      error(path, "invalid_source_ids", "Source IDs must be a non-empty bounded list")
    end
  end

  defp validate_source_ids(_values, path) do
    error(path, "invalid_source_ids", "Source IDs must be a non-empty bounded list")
  end

  defp valid_source_id?(value) when is_binary(value) do
    String.length(value) <= Limits.source_id_characters() and Regex.match?(@source_id, value)
  end

  defp valid_source_id?(_value), do: false

  defp validate_numeric_bounds(rule, path) do
    configured =
      ~w(minimum maximum target tolerance)
      |> Enum.filter(&Map.has_key?(rule, &1))
      |> Enum.map(&{&1, rule[&1]})

    cond do
      configured == [] ->
        error(path, "missing_numeric_bound", "A numeric rule needs a range or target tolerance")

      Enum.any?(configured, fn {_field, value} ->
        not is_number(value) or abs(value) > Limits.max_numeric_magnitude()
      end) ->
        error(
          path,
          "invalid_numeric_bound",
          "Numeric bounds must be interoperable finite JSON numbers"
        )

      Map.has_key?(rule, "target") != Map.has_key?(rule, "tolerance") ->
        error(path, "incomplete_tolerance", "target and tolerance must be configured together")

      is_number(rule["tolerance"]) and rule["tolerance"] < 0 ->
        error(path <> "/tolerance", "invalid_tolerance", "tolerance must be non-negative")

      is_number(rule["minimum"]) and is_number(rule["maximum"]) and
          rule["minimum"] > rule["maximum"] ->
        error(path, "invalid_range", "minimum cannot exceed maximum")

      true ->
        :ok
    end
  end

  defp validate_length_bounds(rule, path) do
    present = Enum.filter(~w(minimum maximum), &Map.has_key?(rule, &1))

    cond do
      present == [] ->
        error(path, "missing_length_bound", "A length rule needs minimum or maximum")

      Enum.any?(present, fn field ->
        value = rule[field]
        not (is_integer(value) and value >= 0 and value <= Limits.output_bytes())
      end) ->
        error(path, "invalid_length_bound", "Length bounds must be bounded non-negative integers")

      Map.has_key?(rule, "minimum") and Map.has_key?(rule, "maximum") and
          rule["minimum"] > rule["maximum"] ->
        error(path, "invalid_range", "minimum cannot exceed maximum")

      true ->
        :ok
    end
  end

  defp validate_distance(value, _path) when is_integer(value) and value >= 1 and value <= 500,
    do: :ok

  defp validate_distance(_value, path) do
    error(path, "invalid_distance", "Citation distance must be an integer from 1 through 500")
  end

  defp validate_boolean(value, _path) when is_boolean(value), do: :ok
  defp validate_boolean(_value, path), do: error(path, "invalid_type", "Value must be a boolean")

  defp validate_enum(value, allowed, path) do
    if value in allowed,
      do: :ok,
      else:
        error(path, "unsupported_value", "Value is not supported by contract schema version 1")
  end

  defp validate_required_fields(map, fields, path) do
    missing = Enum.reject(fields, &Map.has_key?(map, &1))

    if missing == [],
      do: :ok,
      else:
        error(path, "missing_fields", "Rule is missing required fields", %{"fields" => missing})
  end

  defp validate_keys(map, required, optional, path) do
    allowed = required ++ optional
    keys = Map.keys(map)
    missing = required -- keys
    unexpected = keys -- allowed

    cond do
      missing != [] ->
        error(path, "missing_fields", "Object is missing required fields", %{"fields" => missing})

      unexpected != [] ->
        error(path, "unexpected_fields", "Object contains unsupported fields", %{
          "fields" => Enum.sort(unexpected)
        })

      true ->
        :ok
    end
  end

  defp validate_json_value(value, _path)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_json_value(value, path) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> :ok
      {:error, _reason} -> error(path, "invalid_json_value", "Value is not a finite JSON number")
    end
  end

  defp validate_json_value(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_json_value(value, "#{path}/#{index}") do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_json_value(%{__struct__: _module}, path) do
    error(path, "invalid_json_value", "Structs are not contract JSON values")
  end

  defp validate_json_value(value, path) when is_map(value) do
    Enum.reduce_while(value, :ok, fn
      {key, nested}, :ok when is_binary(key) ->
        case validate_json_value(nested, path <> "/" <> escape_pointer(key)) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end

      {_key, _nested}, :ok ->
        {:halt, error(path, "non_string_key", "Contract objects must use string keys")}
    end)
  end

  defp validate_json_value(_value, path) do
    error(path, "invalid_json_value", "Contract must contain only JSON values")
  end

  defp escape_pointer(value), do: value |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp error(path, code, message, details \\ %{}) do
    {:error,
     %{
       "type" => "invalid_contract",
       "path" => path,
       "code" => code,
       "message" => message,
       "details" => details
     }}
  end
end
