defmodule SilentRegression.Spike.Case do
  @moduledoc """
  A versioned prompt, frozen RAG input, and its optional deterministic checks.

  Cases use strings and JSON-compatible check specifications so their persisted
  representation is explicit and safe to round-trip without creating atoms.
  """

  alias SilentRegression.Spike.Validation

  @enforce_keys [
    :id,
    :version,
    :category,
    :description,
    :context,
    :question,
    :response_format
  ]
  defstruct [
    :id,
    :version,
    :category,
    :description,
    :system_prompt,
    :context,
    :question,
    :response_format,
    :fingerprint,
    checks: [],
    tags: []
  ]

  @type check_spec :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          category: String.t(),
          description: String.t(),
          system_prompt: String.t() | nil,
          context: String.t(),
          question: String.t(),
          response_format: String.t(),
          fingerprint: String.t() | nil,
          checks: [check_spec()],
          tags: [String.t()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(attributes) when is_map(attributes) do
    system_prompt = Validation.fetch_optional(attributes, :system_prompt, nil)
    fingerprint = Validation.fetch_optional(attributes, :fingerprint, nil)
    checks = Validation.fetch_optional(attributes, :checks, [])
    tags = Validation.fetch_optional(attributes, :tags, [])

    with {:ok, id} <- Validation.fetch_required(attributes, :id, __MODULE__),
         :ok <- Validation.non_empty_string(id, :id, __MODULE__),
         {:ok, version} <- Validation.fetch_required(attributes, :version, __MODULE__),
         :ok <- Validation.positive_integer(version, :version, __MODULE__),
         {:ok, category} <- Validation.fetch_required(attributes, :category, __MODULE__),
         :ok <- Validation.non_empty_string(category, :category, __MODULE__),
         {:ok, description} <- Validation.fetch_required(attributes, :description, __MODULE__),
         :ok <- Validation.non_empty_string(description, :description, __MODULE__),
         :ok <- Validation.optional_string(system_prompt, :system_prompt, __MODULE__),
         {:ok, context} <- Validation.fetch_required(attributes, :context, __MODULE__),
         :ok <- Validation.non_empty_string(context, :context, __MODULE__),
         {:ok, question} <- Validation.fetch_required(attributes, :question, __MODULE__),
         :ok <- Validation.non_empty_string(question, :question, __MODULE__),
         {:ok, response_format} <-
           Validation.fetch_required(attributes, :response_format, __MODULE__),
         :ok <- Validation.non_empty_string(response_format, :response_format, __MODULE__),
         :ok <- validate_fingerprint(fingerprint),
         :ok <- Validation.json_object_list(checks, :checks, __MODULE__),
         :ok <- Validation.string_list(tags, :tags, __MODULE__) do
      {:ok,
       %__MODULE__{
         id: id,
         version: version,
         category: category,
         description: description,
         system_prompt: system_prompt,
         context: context,
         question: question,
         response_format: response_format,
         fingerprint: fingerprint,
         checks: checks,
         tags: tags
       }}
    end
  end

  def new(_attributes), do: {:error, Validation.error(__MODULE__, :attributes, :must_be_a_map)}

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = case_definition) do
    case case_definition |> Map.from_struct() |> new() do
      {:ok, _validated_case} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = case_definition) do
    %{
      "id" => case_definition.id,
      "version" => case_definition.version,
      "category" => case_definition.category,
      "description" => case_definition.description,
      "system_prompt" => case_definition.system_prompt,
      "context" => case_definition.context,
      "question" => case_definition.question,
      "response_format" => case_definition.response_format,
      "fingerprint" => case_definition.fingerprint,
      "checks" => case_definition.checks,
      "tags" => case_definition.tags
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_fingerprint(nil), do: :ok

  defp validate_fingerprint(fingerprint) when is_binary(fingerprint) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint) do
      :ok
    else
      {:error, Validation.error(__MODULE__, :fingerprint, :must_be_a_sha256_hex_digest)}
    end
  end

  defp validate_fingerprint(_fingerprint) do
    {:error, Validation.error(__MODULE__, :fingerprint, :must_be_a_sha256_hex_digest)}
  end
end
