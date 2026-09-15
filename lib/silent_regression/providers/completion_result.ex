defmodule SilentRegression.Providers.CompletionResult do
  @moduledoc """
  Bounded provider-neutral evidence from one successful network attempt.
  """

  @enforce_keys [
    :provider,
    :requested_model,
    :returned_model,
    :output_text,
    :completion_state,
    :input_tokens,
    :output_tokens,
    :latency_ms,
    :captured_at,
    :metadata
  ]
  defstruct @enforce_keys ++ [:request_id, :finish_reason]

  @type t :: %__MODULE__{
          provider: :openai | :anthropic,
          requested_model: String.t(),
          returned_model: String.t(),
          output_text: String.t(),
          completion_state: :complete | :incomplete,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          latency_ms: non_neg_integer(),
          captured_at: DateTime.t(),
          metadata: map(),
          request_id: String.t() | nil,
          finish_reason: String.t() | nil
        }
end
