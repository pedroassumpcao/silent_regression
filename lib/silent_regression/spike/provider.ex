defmodule SilentRegression.Spike.Provider do
  @moduledoc """
  Contract implemented by each LLM provider used by the spike.

  Expected provider failures are returned as structured values so experiment
  runners can persist and report them without parsing exception text.
  """

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.Validation

  @type error :: %{required(String.t()) => term()}
  @type request_provenance :: %{required(String.t()) => String.t()}

  @callback id() :: String.t()
  @callback request_provenance() :: request_provenance()
  @callback complete(Case.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}

  @spec error(atom(), String.t(), keyword()) :: error()
  def error(type, message, options \\ []) when is_atom(type) and is_binary(message) do
    retryable? = Keyword.get(options, :retryable?, false)
    details = Keyword.get(options, :details, %{})

    unless is_boolean(retryable?) do
      raise ArgumentError, ":retryable? must be a boolean"
    end

    unless is_map(details) and Validation.json_value?(details) do
      raise ArgumentError, ":details must be a JSON object with string keys"
    end

    %{
      "type" => Atom.to_string(type),
      "message" => message,
      "retryable" => retryable?,
      "details" => details
    }
  end
end
