defmodule SilentRegression.Spike.SemanticLayer.ContractEvaluator do
  @moduledoc """
  Applies a validated semantic contract to an immutable output.

  Evaluation is local, deterministic, and explainable. Contract values select
  generic field, fact, source-attribution, and abstention operations; they do
  not alter the stored observation.
  """

  alias SilentRegression.Spike.DeterministicChecks
  alias SilentRegression.Spike.SemanticLayer.ContractSet

  @spec evaluate(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def evaluate(contract, output_text) when is_map(contract) do
    with :ok <- ContractSet.validate_contract(contract) do
      DeterministicChecks.evaluate_checks(contract["case_id"], contract["checks"], output_text)
    end
  end

  def evaluate(_contract, _output_text),
    do: {:error, %{type: :invalid_contract, reason: :must_be_a_map}}
end
