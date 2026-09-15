defmodule SilentRegression.Contracts.Contract do
  @moduledoc """
  Validated, monitor-specific deterministic contract.

  The fingerprint identifies normalized behavior content. Contract identity and
  version are retained separately as provenance.
  """

  alias SilentRegression.Monitors.Fingerprint

  @enforce_keys [
    :schema_version,
    :contract_id,
    :contract_version,
    :monitor_id,
    :root,
    :fingerprint
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          contract_id: String.t(),
          contract_version: pos_integer(),
          monitor_id: String.t(),
          root: map(),
          fingerprint: String.t()
        }

  @spec build(pos_integer(), String.t(), pos_integer(), String.t(), map()) :: t()
  def build(schema_version, contract_id, contract_version, monitor_id, root) do
    %__MODULE__{
      schema_version: schema_version,
      contract_id: contract_id,
      contract_version: contract_version,
      monitor_id: monitor_id,
      root: root,
      fingerprint: fingerprint(schema_version, root)
    }
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = contract) do
    contract.schema_version == 1 and is_binary(contract.contract_id) and
      is_integer(contract.contract_version) and contract.contract_version > 0 and
      is_binary(contract.monitor_id) and is_map(contract.root) and
      contract.fingerprint == fingerprint(contract.schema_version, contract.root)
  end

  @spec to_source_map(t()) :: map()
  def to_source_map(%__MODULE__{} = contract) do
    %{
      "schema_version" => contract.schema_version,
      "contract_id" => contract.contract_id,
      "contract_version" => contract.contract_version,
      "monitor_id" => contract.monitor_id,
      "root" => contract.root
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = contract) do
    Map.put(to_source_map(contract), "fingerprint", contract.fingerprint)
  end

  defp fingerprint(schema_version, root) do
    Fingerprint.digest(%{"schema_version" => schema_version, "root" => root})
  end
end
