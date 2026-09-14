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
    :model_mismatch
  ]

  @enforce_keys [:category, :message, :attempts]
  defstruct [:category, :message, :request_id, :requested_model, :returned_model, :attempts]

  @type category ::
          :authentication
          | :authorization
          | :rate_limited
          | :transport
          | :provider
          | :malformed_response
          | :model_mismatch

  @type t :: %__MODULE__{
          category: category(),
          message: String.t(),
          request_id: String.t() | nil,
          requested_model: String.t() | nil,
          returned_model: String.t() | nil,
          attempts: pos_integer()
        }

  def categories, do: @categories
end
