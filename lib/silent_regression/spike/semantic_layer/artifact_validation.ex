defmodule SilentRegression.Spike.SemanticLayer.ArtifactValidation do
  @moduledoc false

  alias SilentRegression.Spike.Validation

  @spec known_keys(map(), [atom()], module()) :: :ok | {:error, map()}
  def known_keys(attributes, allowed_fields, source) when is_map(attributes) do
    allowed = MapSet.new(Enum.map(allowed_fields, &Atom.to_string/1))
    normalized = Enum.map(Map.keys(attributes), &normalize_key/1)
    unsupported = normalized |> Enum.reject(&MapSet.member?(allowed, &1)) |> Enum.uniq()

    cond do
      unsupported != [] ->
        {:error, error(source, :attributes, :contains_unsupported_fields, %{fields: unsupported})}

      Enum.uniq(normalized) != normalized ->
        {:error, error(source, :attributes, :contains_duplicate_field_aliases)}

      true ->
        :ok
    end
  end

  @spec header(term(), term(), pos_integer(), String.t(), module()) :: :ok | {:error, map()}
  def header(schema_version, artifact_type, expected_version, expected_type, source) do
    cond do
      schema_version != expected_version ->
        {:error,
         %{
           type: :unsupported_schema_version,
           source: source,
           expected: expected_version,
           actual: schema_version
         }}

      artifact_type != expected_type ->
        {:error, error(source, :artifact_type, :unsupported_artifact_type)}

      true ->
        :ok
    end
  end

  @spec exact_json_keys(term(), [String.t()], atom(), module()) :: :ok | {:error, map()}
  def exact_json_keys(value, keys, field, source) do
    with :ok <- Validation.json_object(value, field, source) do
      if Map.keys(value) |> Enum.sort() == Enum.sort(keys),
        do: :ok,
        else: {:error, error(source, field, :must_have_exact_keys, %{keys: keys})}
    end
  end

  @spec enum(term(), [String.t()], atom(), module()) :: :ok | {:error, map()}
  def enum(value, allowed, field, source) do
    if value in allowed,
      do: :ok,
      else: {:error, error(source, field, :unsupported_value, %{allowed: allowed})}
  end

  @spec sha256(term(), atom(), module()) :: :ok | {:error, map()}
  def sha256(value, field, source) do
    if is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: {:error, error(source, field, :must_be_a_lowercase_sha256)}
  end

  @spec unique_strings(term(), atom(), module()) :: :ok | {:error, map()}
  def unique_strings(values, field, source) do
    with :ok <- Validation.string_list(values, field, source) do
      cond do
        values == [] -> {:error, error(source, field, :must_be_a_non_empty_list)}
        Enum.uniq(values) != values -> {:error, error(source, field, :must_be_unique)}
        true -> :ok
      end
    end
  end

  @spec probability(term(), atom(), module(), keyword()) :: :ok | {:error, map()}
  def probability(value, field, source, options \\ []) do
    allow_zero? = Keyword.get(options, :allow_zero, true)
    allow_one? = Keyword.get(options, :allow_one, true)

    valid? =
      is_number(value) and if(allow_zero?, do: value >= 0, else: value > 0) and
        if(allow_one?, do: value <= 1, else: value < 1)

    if valid?,
      do: :ok,
      else: {:error, error(source, field, :must_be_a_probability)}
  end

  @spec source_runs(term(), atom(), module()) :: :ok | {:error, map()}
  def source_runs(sources, field, source) do
    with :ok <- Validation.json_object_list(sources, field, source) do
      cond do
        sources == [] ->
          {:error, error(source, field, :must_be_a_non_empty_list)}

        not Enum.all?(sources, &valid_source_run?(&1, source, field)) ->
          {:error, error(source, field, :must_contain_only_baseline_and_control_runs)}

        sources |> Enum.map(& &1["run_id"]) |> Enum.uniq() !=
            Enum.map(sources, & &1["run_id"]) ->
          {:error, error(source, field, :run_ids_must_be_unique)}

        Enum.count(sources, &(&1["condition"] == "baseline")) != 1 ->
          {:error, error(source, field, :must_contain_exactly_one_baseline)}

        not Enum.any?(sources, &(&1["condition"] == "control")) ->
          {:error, error(source, field, :must_contain_at_least_one_control)}

        true ->
          :ok
      end
    end
  end

  @spec error(module(), atom(), atom(), map()) :: map()
  def error(source, field, reason, details \\ %{}) do
    Validation.error(source, field, reason)
    |> Map.put(:details, details)
  end

  defp valid_source_run?(source_run, source, field) do
    expected_keys = ~w(run_id condition artifact_sha256)

    exact_json_keys(source_run, expected_keys, field, source) == :ok and
      non_empty_string?(source_run["run_id"]) and
      source_run["condition"] in ~w(baseline control) and
      valid_sha256?(source_run["artifact_sha256"])
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
end
