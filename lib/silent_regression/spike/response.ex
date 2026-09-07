defmodule SilentRegression.Spike.Response do
  @moduledoc """
  A provider-neutral successful LLM response.

  Provider clients normalize their response into this contract before runners
  or scoring code see it.
  """

  alias SilentRegression.Spike.Validation

  @enforce_keys [
    :provider,
    :requested_model,
    :returned_model,
    :output_text,
    :usage,
    :latency_ms,
    :captured_at,
    :attempts
  ]
  defstruct [
    :provider,
    :requested_model,
    :returned_model,
    :output_text,
    :request_id,
    :usage,
    :latency_ms,
    :finish_reason,
    :captured_at,
    :raw,
    :attempts
  ]

  @type usage :: %{required(String.t()) => non_neg_integer()}

  @type t :: %__MODULE__{
          provider: String.t(),
          requested_model: String.t(),
          returned_model: String.t(),
          output_text: String.t(),
          request_id: String.t() | nil,
          usage: usage(),
          latency_ms: non_neg_integer(),
          finish_reason: String.t() | nil,
          captured_at: DateTime.t(),
          raw: map(),
          attempts: pos_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(attributes) when is_map(attributes) do
    request_id = Validation.fetch_optional(attributes, :request_id, nil)
    finish_reason = Validation.fetch_optional(attributes, :finish_reason, nil)
    raw = Validation.fetch_optional(attributes, :raw, %{})
    attempts = Validation.fetch_optional(attributes, :attempts, 1)

    with {:ok, provider} <- Validation.fetch_required(attributes, :provider, __MODULE__),
         :ok <- Validation.non_empty_string(provider, :provider, __MODULE__),
         {:ok, requested_model} <-
           Validation.fetch_required(attributes, :requested_model, __MODULE__),
         :ok <- Validation.non_empty_string(requested_model, :requested_model, __MODULE__),
         {:ok, returned_model} <-
           Validation.fetch_required(attributes, :returned_model, __MODULE__),
         :ok <- Validation.non_empty_string(returned_model, :returned_model, __MODULE__),
         {:ok, output_text} <- Validation.fetch_required(attributes, :output_text, __MODULE__),
         :ok <- validate_string(output_text, :output_text),
         :ok <- Validation.optional_string(request_id, :request_id, __MODULE__),
         {:ok, usage} <- Validation.fetch_required(attributes, :usage, __MODULE__),
         {:ok, normalized_usage} <- validate_usage(usage),
         {:ok, latency_ms} <- Validation.fetch_required(attributes, :latency_ms, __MODULE__),
         :ok <- Validation.non_negative_integer(latency_ms, :latency_ms, __MODULE__),
         :ok <- Validation.optional_string(finish_reason, :finish_reason, __MODULE__),
         {:ok, captured_at_value} <-
           Validation.fetch_required(attributes, :captured_at, __MODULE__),
         {:ok, captured_at} <-
           Validation.parse_datetime(captured_at_value, :captured_at, __MODULE__),
         :ok <- Validation.json_object(raw, :raw, __MODULE__),
         :ok <- Validation.positive_integer(attempts, :attempts, __MODULE__) do
      {:ok,
       %__MODULE__{
         provider: provider,
         requested_model: requested_model,
         returned_model: returned_model,
         output_text: output_text,
         request_id: request_id,
         usage: normalized_usage,
         latency_ms: latency_ms,
         finish_reason: finish_reason,
         captured_at: captured_at,
         raw: raw,
         attempts: attempts
       }}
    end
  end

  def new(_attributes), do: {:error, Validation.error(__MODULE__, :attributes, :must_be_a_map)}

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = response) do
    case response |> Map.from_struct() |> new() do
      {:ok, _validated_response} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response) do
    %{
      "provider" => response.provider,
      "requested_model" => response.requested_model,
      "returned_model" => response.returned_model,
      "output_text" => response.output_text,
      "request_id" => response.request_id,
      "usage" => response.usage,
      "latency_ms" => response.latency_ms,
      "finish_reason" => response.finish_reason,
      "captured_at" => DateTime.to_iso8601(response.captured_at),
      "raw" => response.raw,
      "attempts" => response.attempts
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_usage(usage) when is_map(usage) do
    input_tokens = Validation.fetch_optional(usage, :input_tokens, :missing)
    output_tokens = Validation.fetch_optional(usage, :output_tokens, :missing)

    with :ok <- Validation.non_negative_integer(input_tokens, :input_tokens, __MODULE__),
         :ok <- Validation.non_negative_integer(output_tokens, :output_tokens, __MODULE__) do
      {:ok, %{"input_tokens" => input_tokens, "output_tokens" => output_tokens}}
    end
  end

  defp validate_usage(_usage) do
    {:error, Validation.error(__MODULE__, :usage, :must_be_a_token_usage_map)}
  end

  defp validate_string(value, _field) when is_binary(value), do: :ok

  defp validate_string(_value, field) do
    {:error, Validation.error(__MODULE__, field, :must_be_a_string)}
  end
end
