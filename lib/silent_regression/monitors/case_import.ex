defmodule SilentRegression.Monitors.CaseImport do
  @moduledoc """
  Parser for the documented, versioned JSON case import boundary.
  """

  alias SilentRegression.CaseExpectations
  alias SilentRegression.Monitors.{CaseInput, Limits}

  @schema_version 2
  @supported_schema_versions [1, 2]
  @keys ~w(cases schema_version)

  def parse(encoded) when is_binary(encoded) do
    if byte_size(encoded) <= Limits.fetch!(:max_import_bytes) do
      parse_payload(encoded)
    else
      {:error, %{field: :import, reason: :too_large}}
    end
  end

  def parse(_encoded), do: {:error, %{field: :import, reason: :invalid}}

  def schema_version, do: @schema_version

  defp parse_payload(encoded) do
    with {:ok, payload} <- Jason.decode(encoded),
         {:ok, schema_version} <- validate_payload(payload),
         {:ok, cases} <- prepare_cases(Map.get(payload, "cases"), schema_version),
         {:ok, cases} <- CaseInput.normalize_many(cases) do
      {:ok, cases}
    else
      {:error, %Jason.DecodeError{}} -> {:error, %{field: :import, reason: :invalid_json}}
      {:error, reason} -> {:error, reason}
      _reason -> {:error, %{field: :import, reason: :invalid_schema}}
    end
  end

  defp validate_payload(payload) when is_map(payload) do
    if Map.keys(payload) -- @keys == [] and
         Map.get(payload, "schema_version") in @supported_schema_versions do
      {:ok, Map.fetch!(payload, "schema_version")}
    else
      {:error, %{field: :import, reason: :invalid_schema}}
    end
  end

  defp validate_payload(_payload), do: {:error, %{field: :import, reason: :invalid_schema}}

  defp prepare_cases(cases, schema_version) when is_list(cases) do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {case_attributes, index}, {:ok, prepared} ->
      case prepare_case(case_attributes, schema_version) do
        {:ok, case_attributes} -> {:cont, {:ok, [case_attributes | prepared]}}
        {:error, reason} -> {:halt, {:error, Map.put(reason, :case_index, index)}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_cases(_cases, _schema_version),
    do: {:error, %{field: :import, reason: :invalid_schema}}

  defp prepare_case(case_attributes, 1) when is_map(case_attributes) do
    if Map.has_key?(case_attributes, "expectation") or
         Map.has_key?(case_attributes, "expectation_schema_version") do
      {:error, %{field: :expectation, reason: :unsupported_in_schema_v1}}
    else
      {:ok, case_attributes}
    end
  end

  defp prepare_case(case_attributes, 2) when is_map(case_attributes) do
    cond do
      Map.has_key?(case_attributes, "expectation_schema_version") ->
        {:error, %{field: :expectation_schema_version, reason: :server_owned}}

      Map.has_key?(case_attributes, "expectation") ->
        {:ok,
         Map.put(
           case_attributes,
           "expectation_schema_version",
           CaseExpectations.schema_version()
         )}

      true ->
        {:ok, case_attributes}
    end
  end

  defp prepare_case(_case_attributes, _schema_version),
    do: {:error, %{field: :case, reason: :invalid}}
end
