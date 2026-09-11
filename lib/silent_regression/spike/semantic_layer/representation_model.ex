defmodule SilentRegression.Spike.SemanticLayer.RepresentationModel do
  @moduledoc """
  Fitted, local state for one cheap semantic representation.

  The model stores document frequencies learned from baseline/control text.
  It deliberately does not carry fixture labels or evaluation outcomes.
  """

  @enforce_keys [
    :method_name,
    :method_version,
    :parameters,
    :document_count,
    :document_frequencies
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          method_name: String.t(),
          method_version: pos_integer(),
          parameters: map(),
          document_count: pos_integer(),
          document_frequencies: %{optional(String.t()) => non_neg_integer()}
        }
end
