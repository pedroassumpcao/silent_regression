defmodule SilentRegression.Contracts.Evaluation do
  @moduledoc """
  One immutable interpretation of an observation under an exact contract and
  evaluator-engine version.
  """

  alias SilentRegression.Contracts.RuleResult

  @enforce_keys [
    :id,
    :observation_id,
    :contract_id,
    :contract_version,
    :contract_fingerprint,
    :evaluator_engine_version,
    :status,
    :evaluated_at,
    :root_rule_id,
    :rule_results,
    :error
  ]
  defstruct @enforce_keys

  @type status :: :pass | :fail | :evaluator_error
  @type t :: %__MODULE__{
          id: String.t(),
          observation_id: String.t(),
          contract_id: String.t(),
          contract_version: pos_integer(),
          contract_fingerprint: String.t(),
          evaluator_engine_version: String.t(),
          status: status(),
          evaluated_at: DateTime.t(),
          root_rule_id: String.t(),
          rule_results: [RuleResult.t()],
          error: map() | nil
        }

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = evaluation) do
    %{
      "id" => evaluation.id,
      "observation_id" => evaluation.observation_id,
      "contract_id" => evaluation.contract_id,
      "contract_version" => evaluation.contract_version,
      "contract_fingerprint" => evaluation.contract_fingerprint,
      "evaluator_engine_version" => evaluation.evaluator_engine_version,
      "status" => Atom.to_string(evaluation.status),
      "evaluated_at" => DateTime.to_iso8601(evaluation.evaluated_at),
      "root_rule_id" => evaluation.root_rule_id,
      "rule_results" => Enum.map(evaluation.rule_results, &RuleResult.to_map/1),
      "error" => evaluation.error
    }
  end
end
