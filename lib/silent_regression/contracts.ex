defmodule SilentRegression.Contracts do
  @moduledoc """
  Product boundary for versioned deterministic contracts and local evaluation.

  Evaluation never mutates the observation. Repeating an evaluation creates a
  new record with the same deterministic rule outcomes and independent record
  provenance.
  """

  alias SilentRegression.Contracts.{Contract, Evaluation, Evaluator, Limits, Observation, Parser}

  @evaluator_engine_version "deterministic-v1"
  @allowed_options [:evaluation_id, :evaluated_at, :evaluator_engine_version]

  @spec evaluator_engine_version() :: String.t()
  def evaluator_engine_version, do: @evaluator_engine_version

  defdelegate parse_contract(attributes), to: Parser, as: :parse
  defdelegate parse_contract_json(encoded), to: Parser, as: :parse_json
  defdelegate new_observation(attributes), to: Observation, as: :new

  @spec evaluate(Contract.t(), Observation.t(), keyword()) ::
          {:ok, Evaluation.t()} | {:error, map()}
  def evaluate(contract, observation, options \\ [])

  def evaluate(%Contract{} = contract, %Observation{} = observation, options)
      when is_list(options) do
    with :ok <- validate_options(options),
         :ok <- validate_contract(contract),
         {:ok, id} <- evaluation_id(options),
         {:ok, evaluated_at} <- evaluated_at(options),
         {:ok, engine_version} <- engine_version(options) do
      evaluate_record(contract, observation, id, evaluated_at, engine_version)
    end
  end

  def evaluate(_contract, _observation, _options) do
    {:error,
     %{
       "type" => "invalid_evaluation_input",
       "code" => "invalid_evaluation_input",
       "message" => "Evaluation requires a validated contract, observation, and keyword options"
     }}
  end

  @spec rescore(Contract.t(), Observation.t(), keyword()) ::
          {:ok, Evaluation.t()} | {:error, map()}
  def rescore(contract, observation, options \\ []), do: evaluate(contract, observation, options)

  defp evaluate_record(contract, observation, id, evaluated_at, engine_version) do
    cond do
      engine_version != @evaluator_engine_version ->
        {:ok,
         base_evaluation(contract, observation, id, evaluated_at, engine_version, %{
           status: :evaluator_error,
           rule_results: [],
           error: %{
             "code" => "unsupported_evaluator_engine_version",
             "message" => "The requested evaluator engine version is not available"
           }
         })}

      not String.valid?(observation.output_text) ->
        {:ok,
         base_evaluation(contract, observation, id, evaluated_at, engine_version, %{
           status: :evaluator_error,
           rule_results: [],
           error: %{
             "code" => "invalid_output_utf8",
             "message" => "The observation output is not valid UTF-8"
           }
         })}

      byte_size(observation.output_text) > Limits.output_bytes() ->
        {:ok,
         base_evaluation(contract, observation, id, evaluated_at, engine_version, %{
           status: :evaluator_error,
           rule_results: [],
           error: %{
             "code" => "output_too_large",
             "message" => "The observation output exceeds the evaluator byte limit"
           }
         })}

      true ->
        {status, rule_results} = Evaluator.evaluate(contract.root, observation.output_text)

        error =
          if status == :evaluator_error do
            %{
              "code" => "rule_evaluator_error",
              "message" => "At least one contract rule could not be evaluated safely"
            }
          end

        {:ok,
         base_evaluation(contract, observation, id, evaluated_at, engine_version, %{
           status: status,
           rule_results: rule_results,
           error: error
         })}
    end
  end

  defp base_evaluation(contract, observation, id, evaluated_at, engine_version, attributes) do
    %Evaluation{
      id: id,
      observation_id: observation.id,
      contract_id: contract.contract_id,
      contract_version: contract.contract_version,
      contract_fingerprint: contract.fingerprint,
      evaluator_engine_version: engine_version,
      status: attributes.status,
      evaluated_at: evaluated_at,
      root_rule_id: contract.root["id"],
      rule_results: attributes.rule_results,
      error: attributes.error
    }
  end

  defp validate_contract(contract) do
    with {:ok, parsed} <- Parser.parse(Contract.to_source_map(contract)),
         true <- parsed.fingerprint == contract.fingerprint do
      :ok
    else
      {:error, error} ->
        {:error, error}

      false ->
        {:error,
         %{
           "type" => "invalid_contract",
           "code" => "fingerprint_mismatch",
           "message" => "Contract content does not match its fingerprint"
         }}
    end
  end

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        invalid_options("Evaluation options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        invalid_options("Evaluation option keys must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        invalid_options("Evaluation options contain unsupported keys")

      true ->
        :ok
    end
  end

  defp evaluation_id(options) do
    id = Keyword.get(options, :evaluation_id, Ecto.UUID.generate())

    if is_binary(id) and String.valid?(id) and String.trim(id) != "" and byte_size(id) <= 100,
      do: {:ok, id},
      else: invalid_options("evaluation_id must be a non-empty UTF-8 string of at most 100 bytes")
  end

  defp evaluated_at(options) do
    case Keyword.get(options, :evaluated_at, DateTime.utc_now()) do
      %DateTime{} = timestamp -> {:ok, DateTime.truncate(timestamp, :microsecond)}
      _value -> invalid_options("evaluated_at must be a DateTime")
    end
  end

  defp engine_version(options) do
    case Keyword.get(options, :evaluator_engine_version, @evaluator_engine_version) do
      value
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 100 ->
        if String.valid?(value),
          do: {:ok, value},
          else: invalid_options("evaluator_engine_version must be valid UTF-8")

      _value ->
        invalid_options("evaluator_engine_version must be a non-empty bounded string")
    end
  end

  defp invalid_options(message) do
    {:error,
     %{
       "type" => "invalid_evaluation_options",
       "code" => "invalid_evaluation_options",
       "message" => message
     }}
  end
end
