defmodule SilentRegression.Providers.Failure do
  @moduledoc """
  Bounded provider failure safe for persistence and browser presentation.
  """

  @categories [
    :authentication,
    :authorization,
    :rate_limited,
    :transport,
    :provider,
    :malformed_response,
    :model_mismatch,
    :invalid_request,
    :request_too_large,
    :timeout,
    :provider_unavailable,
    :call_cap_exceeded,
    :credential_unavailable,
    :unknown_outcome
  ]

  @enforce_keys [:category, :message, :attempts]
  defstruct [
    :category,
    :message,
    :request_id,
    :requested_model,
    :returned_model,
    :attempts,
    retryable: false,
    latency_ms: nil,
    metadata: %{}
  ]

  @type category ::
          :authentication
          | :authorization
          | :rate_limited
          | :transport
          | :provider
          | :malformed_response
          | :model_mismatch
          | :invalid_request
          | :request_too_large
          | :timeout
          | :provider_unavailable
          | :call_cap_exceeded
          | :credential_unavailable
          | :unknown_outcome

  @type t :: %__MODULE__{
          category: category(),
          message: String.t(),
          request_id: String.t() | nil,
          requested_model: String.t() | nil,
          returned_model: String.t() | nil,
          attempts: pos_integer(),
          retryable: boolean(),
          latency_ms: non_neg_integer() | nil,
          metadata: map()
        }

  def categories, do: @categories
end
