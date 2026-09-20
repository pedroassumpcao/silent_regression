defmodule SilentRegression.Providers.CompletionRequest do
  @moduledoc """
  Provider-neutral input for exactly one managed completion attempt.
  """

  @enforce_keys [
    :case_id,
    :attempt_number,
    :requested_model,
    :request_mode,
    :request_schema_version,
    :request_artifact,
    :request_fingerprint,
    :client_request_id
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          case_id: String.t(),
          attempt_number: pos_integer(),
          requested_model: String.t(),
          request_mode: :legacy_wrapped_v1 | :provider_native_v1,
          request_schema_version: pos_integer(),
          request_artifact: map(),
          request_fingerprint: String.t(),
          client_request_id: String.t()
        }

  def valid?(%__MODULE__{} = request) do
    Enum.all?(
      [
        request.case_id,
        request.requested_model,
        request.request_fingerprint,
        request.client_request_id
      ],
      &bounded_non_empty_string?/1
    ) and
      request.attempt_number > 0 and
      request.request_mode in [:legacy_wrapped_v1, :provider_native_v1] and
      request.request_schema_version == 1 and
      is_map(request.request_artifact) and
      request.request_fingerprint ==
        SilentRegression.Monitors.Fingerprint.digest(request.request_artifact) and
      request.request_artifact["request_mode"] == Atom.to_string(request.request_mode) and
      request.request_artifact["request_schema_version"] == request.request_schema_version and
      get_in(request.request_artifact, ["body", "model"]) == request.requested_model
  end

  def valid?(_request), do: false

  defp bounded_non_empty_string?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      byte_size(value) <= 512
  end
end
