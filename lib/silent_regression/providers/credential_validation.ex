defmodule SilentRegression.Providers.CredentialValidation do
  @moduledoc """
  Safe evidence from a successful provider credential check.
  """

  @enforce_keys [:provider, :attempts]
  defstruct [:provider, :requested_model, :returned_model, :request_id, :attempts]

  @type t :: %__MODULE__{
          provider: :openai | :anthropic,
          requested_model: String.t() | nil,
          returned_model: String.t() | nil,
          request_id: String.t() | nil,
          attempts: pos_integer()
        }
end
