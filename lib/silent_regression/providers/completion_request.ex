defmodule SilentRegression.Providers.CompletionRequest do
  @moduledoc """
  Provider-neutral input for exactly one managed completion attempt.
  """

  @enforce_keys [
    :case_id,
    :attempt_number,
    :requested_model,
    :system_prompt,
    :context,
    :user_prompt,
    :response_format,
    :generation_config,
    :client_request_id
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          case_id: String.t(),
          attempt_number: pos_integer(),
          requested_model: String.t(),
          system_prompt: String.t(),
          context: String.t(),
          user_prompt: String.t(),
          response_format: map(),
          generation_config: map(),
          client_request_id: String.t()
        }

  def valid?(%__MODULE__{} = request) do
    Enum.all?(
      [request.case_id, request.requested_model, request.user_prompt, request.client_request_id],
      &bounded_non_empty_string?/1
    ) and
      request.attempt_number > 0 and
      is_binary(request.system_prompt) and
      is_binary(request.context) and
      is_map(request.response_format) and
      is_map(request.generation_config)
  end

  def valid?(_request), do: false

  defp bounded_non_empty_string?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      byte_size(value) <= 512
  end
end
