defmodule SilentRegression.Contracts.RuleResult do
  @moduledoc """
  Explainable result for one stable contract rule.
  """

  @enforce_keys [
    :rule_id,
    :rule_type,
    :status,
    :code,
    :explanation,
    :evidence,
    :child_rule_ids
  ]
  defstruct @enforce_keys

  @type status :: :pass | :fail | :evaluator_error
  @type t :: %__MODULE__{
          rule_id: String.t(),
          rule_type: String.t(),
          status: status(),
          code: String.t(),
          explanation: String.t(),
          evidence: map(),
          child_rule_ids: [String.t()]
        }

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "rule_id" => result.rule_id,
      "rule_type" => result.rule_type,
      "status" => Atom.to_string(result.status),
      "code" => result.code,
      "explanation" => result.explanation,
      "evidence" => result.evidence,
      "child_rule_ids" => result.child_rule_ids
    }
  end
end
