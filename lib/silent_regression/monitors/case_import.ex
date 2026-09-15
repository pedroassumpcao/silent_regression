defmodule SilentRegression.Monitors.CaseImport do
  @moduledoc """
  Parser for the documented, versioned JSON case import boundary.
  """

  alias SilentRegression.Monitors.{CaseInput, Limits}

  @schema_version 1
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
         :ok <- validate_payload(payload),
         {:ok, cases} <- CaseInput.normalize_many(Map.get(payload, "cases")) do
      {:ok, cases}
    else
      {:error, %Jason.DecodeError{}} -> {:error, %{field: :import, reason: :invalid_json}}
      {:error, reason} -> {:error, reason}
      _reason -> {:error, %{field: :import, reason: :invalid_schema}}
    end
  end

  defp validate_payload(payload) when is_map(payload) do
    if Map.keys(payload) -- @keys == [] and
         Map.get(payload, "schema_version") == @schema_version do
      :ok
    else
      {:error, %{field: :import, reason: :invalid_schema}}
    end
  end

  defp validate_payload(_payload), do: {:error, %{field: :import, reason: :invalid_schema}}
end
