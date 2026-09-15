defmodule SilentRegression.Monitors.CaseInput do
  @moduledoc false

  alias SilentRegression.Monitors.{Fingerprint, JsonValue, Limits}

  @keys ~w(case_key name position status input_variables frozen_context)
  @statuses %{"active" => :active, "disabled" => :disabled}

  def normalize_many(cases) when is_list(cases) and cases != [] do
    with true <- length(cases) <= Limits.fetch!(:max_total_cases),
         {:ok, cases} <- normalize_cases(cases),
         :ok <- validate_unique(cases, :case_key),
         :ok <- validate_unique(cases, :position),
         :ok <- validate_active_count(cases) do
      {:ok, Enum.sort_by(cases, & &1.position)}
    else
      false -> {:error, %{field: :cases, reason: :too_many_cases}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_many(_cases), do: {:error, %{field: :cases, reason: :must_not_be_empty}}

  def normalize(
        %{
          case_key: _case_key,
          name: _name,
          position: _position,
          status: status,
          input_variables: _input_variables,
          frozen_context: _frozen_context,
          fingerprint: _fingerprint
        } = attributes,
        default_position
      )
      when status in [:active, :disabled] do
    attributes
    |> Map.delete(:fingerprint)
    |> Map.put(:status, Atom.to_string(status))
    |> normalize(default_position)
  end

  def normalize(attributes, default_position) when is_map(attributes) do
    with {:ok, attributes} <- JsonValue.normalize(attributes),
         [] <- Map.keys(attributes) -- @keys,
         {:ok, case_key} <- case_key(attributes),
         {:ok, name} <- name(attributes),
         {:ok, position} <- position(attributes, default_position),
         {:ok, status} <- status(attributes),
         {:ok, input_variables} <- input_variables(attributes),
         {:ok, frozen_context} <- frozen_context(attributes) do
      normalized = %{
        case_key: case_key,
        name: name,
        position: position,
        status: status,
        input_variables: input_variables,
        frozen_context: frozen_context
      }

      {:ok, Map.put(normalized, :fingerprint, Fingerprint.case_digest(normalized))}
    else
      _reason -> {:error, %{field: :case, reason: :invalid}}
    end
  end

  def normalize(_attributes, _default_position),
    do: {:error, %{field: :case, reason: :invalid}}

  defp normalize_cases(cases) do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attributes, index}, {:ok, normalized} ->
      case normalize(attributes, index) do
        {:ok, case_attributes} ->
          {:cont, {:ok, [case_attributes | normalized]}}

        {:error, error} ->
          {:halt, {:error, Map.put(error, :case_index, index)}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, error} -> {:error, error}
    end
  end

  defp case_key(attributes) do
    case Map.get(attributes, "case_key", "") do
      value when is_binary(value) ->
        value = String.trim(value)

        if byte_size(value) in 2..80 and
             Regex.match?(~r/^[a-z0-9]+(?:[-_][a-z0-9]+)*$/, value) do
          {:ok, value}
        else
          {:error, :invalid_case_key}
        end

      _value ->
        {:error, :invalid_case_key}
    end
  end

  defp name(attributes) do
    case Map.get(attributes, "name", "") do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" and byte_size(value) <= 160,
          do: {:ok, value},
          else: {:error, :invalid_name}

      _value ->
        {:error, :invalid_name}
    end
  end

  defp position(attributes, default_position) do
    value = Map.get(attributes, "position", default_position)

    if is_integer(value) and value >= 0,
      do: {:ok, value},
      else: {:error, :invalid_position}
  end

  defp status(attributes) do
    case Map.get(attributes, "status", "active") do
      value when is_map_key(@statuses, value) -> {:ok, Map.fetch!(@statuses, value)}
      _value -> {:error, :invalid_status}
    end
  end

  defp input_variables(attributes) do
    value = Map.get(attributes, "input_variables", %{})

    with true <- is_map(value),
         {:ok, size} <- JsonValue.encoded_size(value),
         true <- size <= Limits.fetch!(:max_variables_bytes) do
      {:ok, value}
    else
      _reason -> {:error, :invalid_input_variables}
    end
  end

  defp frozen_context(attributes) do
    value = Map.get(attributes, "frozen_context", "")

    if is_binary(value) and String.valid?(value) and
         byte_size(value) <= Limits.fetch!(:max_context_bytes) do
      {:ok, value}
    else
      {:error, :invalid_frozen_context}
    end
  end

  defp validate_unique(cases, field) do
    values = Enum.map(cases, &Map.fetch!(&1, field))

    if Enum.uniq(values) == values,
      do: :ok,
      else: {:error, %{field: field, reason: :duplicate}}
  end

  defp validate_active_count(cases) do
    count = Enum.count(cases, &(&1.status == :active))

    if count in 1..Limits.fetch!(:max_active_cases),
      do: :ok,
      else: {:error, %{field: :cases, reason: :invalid_active_case_count}}
  end
end
