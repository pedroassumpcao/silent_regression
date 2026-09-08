defmodule SilentRegression.Spike.Control do
  @moduledoc """
  Plans, captures, and compares a held-out same-model control run.

  The baseline artifact supplies the frozen case snapshots. Provider, model,
  endpoint, generation settings, case fingerprints, and returned model must
  match before a comparison is accepted. Dry runs perform all pre-call checks
  without provider requests or artifact writes.
  """

  alias SilentRegression.Spike.Baseline
  alias SilentRegression.Spike.Calibration
  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Run

  @default_samples_per_case 20
  @allowed_options [
    :availability_checker,
    :calibration,
    :clock,
    :dry_run,
    :environment,
    :git_revision,
    :label,
    :max_calls,
    :max_concurrency,
    :max_retries,
    :model,
    :output_path,
    :permutations,
    :provider_options,
    :run_id,
    :samples_per_case,
    :seed
  ]
  @capture_options @allowed_options -- [:calibration, :permutations, :seed]

  @type result :: %{required(String.t()) => term()}

  @doc "Returns the complete control plan without making provider requests."
  @spec plan(Run.t(), module(), keyword()) :: {:ok, map()} | {:error, map()}
  def plan(%Run{} = baseline, provider, options) when is_list(options) do
    with :ok <- validate_options(options),
         {:ok, seed} <- required_integer(options, :seed),
         {:ok, permutations} <- positive_integer(options, :permutations, 999),
         {:ok, calibration} <- optional_calibration(options),
         {:ok, run_id} <- run_id(options),
         {:ok, label} <- label(options, baseline),
         {:ok, output_path} <- output_path(options, run_id),
         capture_options <-
           capture_options(options, run_id, label, output_path),
         {:ok, baseline_plan} <- Baseline.plan(baseline.cases, provider, capture_options),
         control_plan <-
           baseline_plan
           |> Map.put("condition", "control")
           |> Map.put("baseline_run_id", baseline.run_id)
           |> Map.put("comparison_seed", seed)
           |> Map.put("permutations", permutations)
           |> Map.put("calibration_id", calibration_id(calibration)),
         :ok <- Comparison.validate_capture_plan(baseline, control_plan),
         :ok <-
           Comparison.validate_calibration_for_plan(calibration, baseline, control_plan) do
      {:ok, control_plan}
    end
  end

  def plan(_baseline, _provider, _options),
    do: configuration_error("Control planning requires a baseline and keyword options")

  @doc "Runs a dry plan or captures, persists, and compares one live control."
  @spec run(Run.t(), module(), keyword()) :: {:ok, result()} | {:error, map()}
  def run(%Run{} = baseline, provider, options) when is_list(options) do
    with {:ok, control_plan} <- plan(baseline, provider, options) do
      if Keyword.get(options, :dry_run, false) do
        {:ok,
         %{
           "status" => "dry_run",
           "plan" => control_plan,
           "artifact_path" => nil,
           "comparison" => nil
         }}
      else
        execute(baseline, provider, options, control_plan)
      end
    end
  end

  def run(_baseline, _provider, _options),
    do: configuration_error("Control execution requires a baseline and keyword options")

  defp execute(baseline, provider, options, control_plan) do
    capture_options =
      options
      |> Keyword.take(@capture_options)
      |> Keyword.put(:run_id, control_plan["run_id"])
      |> Keyword.put(:label, control_plan["label"])
      |> Keyword.put(:output_path, control_plan["artifact_path"])
      |> Keyword.put(:samples_per_case, control_plan["samples_per_case"])
      |> Keyword.put(:dry_run, false)

    with {:ok, capture} <-
           Baseline.execute_plan(baseline.cases, provider, capture_options, control_plan),
         {:ok, comparison} <-
           Comparison.compare(baseline, capture["run"],
             seed: control_plan["comparison_seed"],
             permutations: control_plan["permutations"],
             calibration: Keyword.get(options, :calibration)
           ) do
      {:ok,
       capture
       |> Map.put("comparison", comparison)
       |> Map.put("status", "completed")}
    else
      {:error, error} -> {:error, add_artifact_context(error, control_plan["artifact_path"])}
    end
  end

  defp capture_options(options, run_id, label, output_path) do
    options
    |> Keyword.take(@capture_options)
    |> Keyword.put_new(:samples_per_case, @default_samples_per_case)
    |> Keyword.put(:run_id, run_id)
    |> Keyword.put(:label, label)
    |> Keyword.put(:output_path, output_path)
  end

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        configuration_error("Control options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        configuration_error("Control options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        configuration_error("Control options contain unsupported keys",
          unsupported_options:
            Enum.map(Keyword.keys(options) -- @allowed_options, &Atom.to_string/1)
        )

      true ->
        :ok
    end
  end

  defp optional_calibration(options) do
    case Keyword.get(options, :calibration) do
      nil -> {:ok, nil}
      %Calibration{} = calibration -> {:ok, calibration}
      _value -> configuration_error("Calibration must be a calibration artifact")
    end
  end

  defp required_integer(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> configuration_error("Control #{name} must be an integer")
      :error -> configuration_error("Control #{name} is required")
    end
  end

  defp positive_integer(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      configuration_error("Control #{name} must be a positive integer")
    end
  end

  defp run_id(options) do
    value = Keyword.get_lazy(options, :run_id, &generate_run_id/0)

    if non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Control run_id must be a non-empty string")
    end
  end

  defp generate_run_id do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = System.unique_integer([:positive, :monotonic])
    "control-#{timestamp}-#{suffix}"
  end

  defp label(options, baseline) do
    value =
      Keyword.get(
        options,
        :label,
        "#{baseline.provider} #{baseline.request_config["model"]} control"
      )

    if non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Control label must be a non-empty string")
    end
  end

  defp output_path(options, run_id) do
    value = Keyword.get(options, :output_path, Path.join("results/drift_spike", "#{run_id}.json"))

    if non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Control output_path must be a non-empty string")
    end
  end

  defp non_empty_string?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp non_empty_string?(_value), do: false

  defp calibration_id(nil), do: nil
  defp calibration_id(%Calibration{calibration_id: calibration_id}), do: calibration_id

  defp add_artifact_context(error, artifact_path) when is_map(error) do
    details = Map.get(error, "details", %{}) |> Map.put("control_artifact_path", artifact_path)
    Map.put(error, "details", details)
  end

  defp add_artifact_context(error, _artifact_path), do: error

  defp configuration_error(message, details \\ []) do
    {:error,
     Provider.error(:configuration_error, message,
       details: Map.new(details, fn {key, value} -> {Atom.to_string(key), value} end)
     )}
  end
end
