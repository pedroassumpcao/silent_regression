defmodule SilentRegression.Spike.Validation do
  @moduledoc false

  @spec fetch_required(map(), atom(), module()) :: {:ok, term()} | {:error, map()}
  def fetch_required(attributes, field, source) when is_map(attributes) do
    case fetch(attributes, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error(source, field, :required)}
    end
  end

  @spec fetch_optional(map(), atom(), term()) :: term()
  def fetch_optional(attributes, field, default) when is_map(attributes) do
    case fetch(attributes, field) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @spec non_empty_string(term(), atom(), module()) :: :ok | {:error, map()}
  def non_empty_string(value, field, source) do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:error, error(source, field, :must_be_a_non_empty_string)}
    end
  end

  @spec optional_string(term(), atom(), module()) :: :ok | {:error, map()}
  def optional_string(nil, _field, _source), do: :ok
  def optional_string(value, field, source), do: non_empty_string(value, field, source)

  @spec positive_integer(term(), atom(), module()) :: :ok | {:error, map()}
  def positive_integer(value, field, source) do
    if is_integer(value) and value > 0 do
      :ok
    else
      {:error, error(source, field, :must_be_a_positive_integer)}
    end
  end

  @spec non_negative_integer(term(), atom(), module()) :: :ok | {:error, map()}
  def non_negative_integer(value, field, source) do
    if is_integer(value) and value >= 0 do
      :ok
    else
      {:error, error(source, field, :must_be_a_non_negative_integer)}
    end
  end

  @spec string_list(term(), atom(), module()) :: :ok | {:error, map()}
  def string_list(value, field, source) do
    if is_list(value) and Enum.all?(value, &non_empty_string?/1) do
      :ok
    else
      {:error, error(source, field, :must_be_a_list_of_non_empty_strings)}
    end
  end

  @spec json_object(term(), atom(), module()) :: :ok | {:error, map()}
  def json_object(value, field, source) do
    if is_map(value) and json_value?(value) do
      :ok
    else
      {:error, error(source, field, :must_be_a_json_object_with_string_keys)}
    end
  end

  @spec json_object_list(term(), atom(), module()) :: :ok | {:error, map()}
  def json_object_list(value, field, source) do
    if is_list(value) and Enum.all?(value, &(is_map(&1) and json_value?(&1))) do
      :ok
    else
      {:error, error(source, field, :must_be_a_list_of_json_objects)}
    end
  end

  @spec datetime(term(), atom(), module()) :: :ok | {:error, map()}
  def datetime(%DateTime{}, _field, _source), do: :ok
  def datetime(_value, field, source), do: {:error, error(source, field, :must_be_a_datetime)}

  @spec parse_datetime(term(), atom(), module()) :: {:ok, DateTime.t()} | {:error, map()}
  def parse_datetime(%DateTime{} = value, _field, _source), do: {:ok, value}

  def parse_datetime(value, field, source) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, error(source, field, :must_be_an_iso8601_datetime)}
    end
  end

  def parse_datetime(_value, field, source) do
    {:error, error(source, field, :must_be_an_iso8601_datetime)}
  end

  @spec error(module(), atom(), atom()) :: map()
  def error(source, field, reason) do
    %{type: :validation_error, source: source, field: field, reason: reason}
  end

  @spec json_value?(term()) :: boolean()
  def json_value?(value) when is_binary(value) or is_boolean(value) or is_nil(value), do: true
  def json_value?(value) when is_integer(value) or is_float(value), do: true
  def json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  def json_value?(value) when is_struct(value), do: false

  def json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested_value} ->
      is_binary(key) and json_value?(nested_value)
    end)
  end

  def json_value?(_value), do: false

  defp fetch(attributes, field) do
    case Map.fetch(attributes, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attributes, Atom.to_string(field))
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
