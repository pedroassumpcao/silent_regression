defmodule SilentRegression.Spike.Run do
  @moduledoc """
  A complete, versioned drift-spike run ready for local persistence.

  Run artifacts contain case snapshots and JSON-compatible ordered sample
  records so later comparisons can validate provenance before scoring.
  """

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Validation

  @schema_version 1
  @conditions ~w(
    baseline
    control
    harmless_rewording
    subtle_regression
    mixed_regression
    obvious_regression
  )

  @enforce_keys [
    :schema_version,
    :run_id,
    :label,
    :condition,
    :started_at,
    :completed_at,
    :provider,
    :request_config,
    :cases,
    :samples,
    :metrics,
    :totals
  ]
  defstruct [
    :schema_version,
    :run_id,
    :label,
    :condition,
    :started_at,
    :completed_at,
    :git_revision,
    :provider,
    :request_config,
    :cases,
    :samples,
    :metrics,
    :totals
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          run_id: String.t(),
          label: String.t(),
          condition: String.t(),
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          git_revision: String.t() | nil,
          provider: String.t(),
          request_config: map(),
          cases: [Case.t()],
          samples: [map()],
          metrics: map(),
          totals: map()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec conditions() :: [String.t()]
  def conditions, do: @conditions

  @spec new(map()) :: {:ok, t()} | {:error, map()}
  def new(attributes) when is_map(attributes) do
    schema_version = Validation.fetch_optional(attributes, :schema_version, @schema_version)
    git_revision = Validation.fetch_optional(attributes, :git_revision, nil)

    with :ok <- validate_schema_version(schema_version),
         {:ok, run_id} <- Validation.fetch_required(attributes, :run_id, __MODULE__),
         :ok <- Validation.non_empty_string(run_id, :run_id, __MODULE__),
         {:ok, label} <- Validation.fetch_required(attributes, :label, __MODULE__),
         :ok <- Validation.non_empty_string(label, :label, __MODULE__),
         {:ok, condition} <- Validation.fetch_required(attributes, :condition, __MODULE__),
         :ok <- validate_condition(condition),
         {:ok, started_at_value} <-
           Validation.fetch_required(attributes, :started_at, __MODULE__),
         {:ok, started_at} <-
           Validation.parse_datetime(started_at_value, :started_at, __MODULE__),
         {:ok, completed_at_value} <-
           Validation.fetch_required(attributes, :completed_at, __MODULE__),
         {:ok, completed_at} <-
           Validation.parse_datetime(completed_at_value, :completed_at, __MODULE__),
         :ok <- validate_time_order(started_at, completed_at),
         :ok <- Validation.optional_string(git_revision, :git_revision, __MODULE__),
         {:ok, provider} <- Validation.fetch_required(attributes, :provider, __MODULE__),
         :ok <- Validation.non_empty_string(provider, :provider, __MODULE__),
         {:ok, request_config} <-
           Validation.fetch_required(attributes, :request_config, __MODULE__),
         :ok <- Validation.json_object(request_config, :request_config, __MODULE__),
         {:ok, case_values} <- Validation.fetch_required(attributes, :cases, __MODULE__),
         {:ok, cases} <- validate_cases(case_values),
         {:ok, samples} <- Validation.fetch_required(attributes, :samples, __MODULE__),
         :ok <- Validation.json_object_list(samples, :samples, __MODULE__),
         {:ok, metrics} <- Validation.fetch_required(attributes, :metrics, __MODULE__),
         :ok <- Validation.json_object(metrics, :metrics, __MODULE__),
         {:ok, totals} <- Validation.fetch_required(attributes, :totals, __MODULE__),
         :ok <- Validation.json_object(totals, :totals, __MODULE__) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         run_id: run_id,
         label: label,
         condition: condition,
         started_at: started_at,
         completed_at: completed_at,
         git_revision: git_revision,
         provider: provider,
         request_config: request_config,
         cases: cases,
         samples: samples,
         metrics: metrics,
         totals: totals
       }}
    end
  end

  def new(_attributes), do: {:error, Validation.error(__MODULE__, :attributes, :must_be_a_map)}

  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = run) do
    case run |> Map.from_struct() |> new() do
      {:ok, _validated_run} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = run) do
    %{
      "schema_version" => run.schema_version,
      "run_id" => run.run_id,
      "label" => run.label,
      "condition" => run.condition,
      "started_at" => DateTime.to_iso8601(run.started_at),
      "completed_at" => DateTime.to_iso8601(run.completed_at),
      "git_revision" => run.git_revision,
      "provider" => run.provider,
      "request_config" => run.request_config,
      "cases" => Enum.map(run.cases, &Case.to_map/1),
      "samples" => run.samples,
      "metrics" => run.metrics,
      "totals" => run.totals
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, map()}
  def from_map(attributes), do: new(attributes)

  defp validate_schema_version(@schema_version), do: :ok

  defp validate_schema_version(version) do
    {:error,
     %{
       type: :unsupported_schema_version,
       source: __MODULE__,
       expected: @schema_version,
       actual: version
     }}
  end

  defp validate_condition(condition) when condition in @conditions, do: :ok

  defp validate_condition(_condition) do
    {:error, Validation.error(__MODULE__, :condition, :unsupported_condition)}
  end

  defp validate_time_order(started_at, completed_at) do
    if DateTime.compare(completed_at, started_at) in [:eq, :gt] do
      :ok
    else
      {:error, Validation.error(__MODULE__, :completed_at, :must_not_precede_started_at)}
    end
  end

  defp validate_cases(cases) when is_list(cases) and cases != [] do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {case_value, index}, {:ok, validated_cases} ->
      case validate_case(case_value) do
        {:ok, case_definition} ->
          {:cont, {:ok, [case_definition | validated_cases]}}

        {:error, error} ->
          {:halt,
           {:error,
            %{
              type: :invalid_case,
              source: __MODULE__,
              field: :cases,
              index: index,
              cause: error
            }}}
      end
    end)
    |> case do
      {:ok, validated_cases} -> {:ok, Enum.reverse(validated_cases)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_cases(_cases) do
    {:error, Validation.error(__MODULE__, :cases, :must_be_a_non_empty_list)}
  end

  defp validate_case(%Case{} = case_definition) do
    case Case.validate(case_definition) do
      :ok -> {:ok, case_definition}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_case(case_definition) when is_map(case_definition),
    do: Case.from_map(case_definition)

  defp validate_case(_case_definition) do
    {:error, Validation.error(Case, :attributes, :must_be_a_map)}
  end
end
