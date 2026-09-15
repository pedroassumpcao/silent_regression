defmodule SilentRegression.Contracts.Observation do
  @moduledoc """
  Immutable evaluator input.

  Task 9 will add provider and capture provenance around this boundary. The
  deterministic engine reads only the stable observation ID and output bytes.
  """

  @enforce_keys [:id, :output_text]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), output_text: binary()}

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(%{"id" => id, "output_text" => output_text} = attributes)
      when map_size(attributes) == 2 and is_binary(id) and is_binary(output_text) do
    if String.valid?(id) and String.trim(id) != "" and byte_size(id) <= 100 do
      {:ok, %__MODULE__{id: id, output_text: output_text}}
    else
      {:error, invalid("Observation ID must be a non-empty UTF-8 string of at most 100 bytes")}
    end
  end

  def new(_attributes) do
    {:error, invalid("Observation must contain only string id and output_text fields")}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = observation) do
    %{"id" => observation.id, "output_text" => observation.output_text}
  end

  defp invalid(message) do
    %{"type" => "invalid_observation", "code" => "invalid_observation", "message" => message}
  end
end
