defmodule SilentRegression.Spike.Baseline do
  @moduledoc """
  Plans, captures, scores, and atomically persists a baseline sample pool.

  A live baseline always spends one request checking authenticated model access
  before generation. The remaining call budget is delegated to `Runner`, which
  reserves all configured retries before any generation starts. Dry runs
  perform the same validation and budgeting but make no requests and write no
  artifact.
  """

  alias SilentRegression.Spike.ModelAvailability
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.RunAnalysis
  alias SilentRegression.Spike.Runner
  alias SilentRegression.Spike.Storage
  alias SilentRegression.Spike.Validation

  @availability_calls 1
  @default_samples_per_case 30
  @allowed_options [
    :availability_checker,
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
    :provider_options,
    :run_id,
    :samples_per_case
  ]

  @type plan :: %{required(String.t()) => term()}
  @type result :: %{required(String.t()) => term()}

  @doc "Returns the complete baseline plan without making provider requests."
  @spec plan([SilentRegression.Spike.Case.t()], module(), keyword()) ::
          {:ok, plan()} | {:error, Provider.error()}
  def plan(cases, provider, options) do
    with :ok <- validate_options(options),
         {:ok, max_calls} <- required_max_calls(options),
         {:ok, runner_max_calls} <- generation_call_cap(max_calls),
         {:ok, runner_plan} <-
           build_runner_plan(
             cases,
             provider,
             runner_options(options, runner_max_calls),
             max_calls
           ),
         {:ok, run_id} <- run_id(options),
         {:ok, label} <- label(options, runner_plan),
         {:ok, output_path} <- output_path(options, run_id),
         {:ok, git_revision} <- git_revision(options),
         :ok <- validate_runtime_options(options) do
      {:ok,
       runner_plan
       |> Map.put("artifact_path", output_path)
       |> Map.put("availability_calls", @availability_calls)
       |> Map.put("generation_calls", runner_plan["planned_calls"])
       |> Map.put("planned_calls", runner_plan["planned_calls"] + @availability_calls)
       |> Map.put("maximum_calls", runner_plan["maximum_calls"] + @availability_calls)
       |> Map.put("max_calls", max_calls)
       |> Map.put("run_id", run_id)
       |> Map.put("label", label)
       |> Map.put("condition", "baseline")
       |> Map.put("git_revision", git_revision)}
    end
  end

  @doc """
  Runs a dry plan or captures one live baseline artifact.

  A successful live result includes the validated `Run` struct, the persisted
  artifact path, and the same plan shown in dry-run mode.
  """
  @spec run([SilentRegression.Spike.Case.t()], module(), keyword()) ::
          {:ok, result()} | {:error, Provider.error() | map()}
  def run(cases, provider, options) do
    with {:ok, baseline_plan} <- plan(cases, provider, options) do
      if Keyword.get(options, :dry_run, false) do
        {:ok, dry_run_result(baseline_plan)}
      else
        execute_plan(cases, provider, options, baseline_plan)
      end
    end
  end

  @doc false
  @spec execute_plan([SilentRegression.Spike.Case.t()], module(), keyword(), plan()) ::
          {:ok, result()} | {:error, Provider.error() | map()}
  def execute_plan(cases, provider, options, capture_plan) do
    execute(cases, provider, options, capture_plan)
  end

  defp validate_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)
      unsupported = keys -- @allowed_options

      cond do
        Enum.uniq(keys) != keys ->
          configuration_error("Baseline options contain duplicate keys", %{"field" => "options"})

        unsupported != [] ->
          configuration_error("Baseline options contain unsupported keys", %{
            "unsupported_options" => Enum.map(unsupported, &Atom.to_string/1)
          })

        true ->
          :ok
      end
    else
      configuration_error("Baseline options must be a keyword list", %{"field" => "options"})
    end
  end

  defp validate_options(_options) do
    configuration_error("Baseline options must be a keyword list", %{"field" => "options"})
  end

  defp required_max_calls(options) do
    case Keyword.fetch(options, :max_calls) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, _value} ->
        configuration_error("Baseline max_calls must be a positive integer", %{
          "field" => "max_calls"
        })

      :error ->
        configuration_error("Baseline max_calls is required", %{"field" => "max_calls"})
    end
  end

  defp generation_call_cap(max_calls) when max_calls > @availability_calls do
    {:ok, max_calls - @availability_calls}
  end

  defp generation_call_cap(max_calls) do
    {:error,
     Provider.error(
       :call_budget_exceeded,
       "The max-calls cap cannot cover model access and generation",
       details: %{
         "availability_calls" => @availability_calls,
         "max_calls" => max_calls,
         "minimum_calls" => @availability_calls + 1
       }
     )}
  end

  defp runner_options(options, runner_max_calls) do
    options
    |> Keyword.take([
      :environment,
      :max_concurrency,
      :max_retries,
      :model,
      :provider_options,
      :samples_per_case
    ])
    |> Keyword.put_new(:samples_per_case, @default_samples_per_case)
    |> Keyword.put(:max_calls, runner_max_calls)
  end

  defp build_runner_plan(cases, provider, options, total_max_calls) do
    case Runner.plan(cases, provider, options) do
      {:error, %{"type" => "call_budget_exceeded", "details" => details}} ->
        {:error,
         Provider.error(
           :call_budget_exceeded,
           "Planned model access, generation calls, and retry reserve exceed the max-calls cap",
           details: %{
             "availability_calls" => @availability_calls,
             "planned_calls" => details["planned_calls"] + @availability_calls,
             "generation_calls" => details["planned_calls"],
             "retry_calls_reserved" => details["retry_calls_reserved"],
             "maximum_calls" => details["maximum_calls"] + @availability_calls,
             "max_calls" => total_max_calls
           }
         )}

      result ->
        result
    end
  end

  defp run_id(options) do
    value = Keyword.get_lazy(options, :run_id, &generate_run_id/0)

    if non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Baseline run_id must be a non-empty string", %{"field" => "run_id"})
    end
  end

  defp generate_run_id do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = System.unique_integer([:positive, :monotonic])
    "baseline-#{timestamp}-#{suffix}"
  end

  defp label(options, runner_plan) do
    value =
      Keyword.get(
        options,
        :label,
        "#{runner_plan["provider"]} #{runner_plan["model"]} baseline"
      )

    if non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Baseline label must be a non-empty string", %{"field" => "label"})
    end
  end

  defp output_path(options, run_id) do
    value = Keyword.get(options, :output_path, Path.join("results/drift_spike", "#{run_id}.json"))

    if non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Baseline output_path must be a non-empty string", %{
        "field" => "output_path"
      })
    end
  end

  defp git_revision(options) do
    value =
      if Keyword.has_key?(options, :git_revision) do
        Keyword.fetch!(options, :git_revision)
      else
        current_git_revision()
      end

    if is_nil(value) or non_empty_string?(value) do
      {:ok, value}
    else
      configuration_error("Baseline git_revision must be nil or a non-empty string", %{
        "field" => "git_revision"
      })
    end
  end

  defp current_git_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} ->
        case String.trim(revision) do
          "" -> nil
          value -> value
        end

      {_output, _status} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp validate_runtime_options(options) do
    with :ok <- validate_availability_checker(Keyword.get(options, :availability_checker)),
         :ok <- validate_clock(Keyword.get(options, :clock)) do
      :ok
    end
  end

  defp validate_availability_checker(nil), do: :ok
  defp validate_availability_checker(checker) when is_function(checker, 3), do: :ok

  defp validate_availability_checker(_checker) do
    configuration_error("Baseline availability_checker must accept three arguments", %{
      "field" => "availability_checker"
    })
  end

  defp validate_clock(nil), do: :ok
  defp validate_clock(clock) when is_function(clock, 0), do: :ok

  defp validate_clock(_clock) do
    configuration_error("Baseline clock must be a zero-argument function", %{"field" => "clock"})
  end

  defp non_empty_string?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp non_empty_string?(_value), do: false

  defp dry_run_result(baseline_plan) do
    %{
      "status" => "dry_run",
      "plan" => baseline_plan,
      "artifact_path" => nil,
      "totals" => %{
        "planned_samples" => baseline_plan["planned_samples"],
        "planned_calls" => baseline_plan["planned_calls"],
        "maximum_calls" => baseline_plan["maximum_calls"],
        "actual_calls" => 0,
        "successful_samples" => 0,
        "failed_samples" => 0,
        "completed_samples" => 0,
        "incomplete_samples" => 0,
        "unknown_completion_samples" => 0,
        "quality_passed_samples" => 0,
        "quality_failed_samples" => 0
      }
    }
  end

  defp execute(cases, provider, options, baseline_plan) do
    with :ok <- ensure_http_client_started(),
         {:ok, started_at} <- timestamp(options),
         {:ok, availability} <- check_availability(provider, options, baseline_plan),
         {:ok, runner_result} <- run_generation(cases, provider, options, baseline_plan),
         {:ok, %{"samples" => samples, "metrics" => metrics}} <-
           RunAnalysis.analyze(cases, runner_result["samples"]),
         {:ok, completed_at} <- timestamp(options),
         totals <- build_totals(baseline_plan, runner_result["totals"], samples, metrics),
         {:ok, run} <-
           build_run(
             baseline_plan,
             availability,
             cases,
             samples,
             metrics,
             totals,
             started_at,
             completed_at
           ),
         :ok <- Storage.write(baseline_plan["artifact_path"], run) do
      {:ok,
       %{
         "status" => "completed",
         "plan" => baseline_plan,
         "artifact_path" => baseline_plan["artifact_path"],
         "run" => run,
         "totals" => totals,
         "metrics" => metrics
       }}
    end
  end

  defp ensure_http_client_started do
    case Application.ensure_all_started(:req) do
      {:ok, _started_applications} ->
        :ok

      {:error, {application, reason}} ->
        {:error,
         Provider.error(:http_client_start_failed, "The HTTP client could not be started",
           details: %{
             "application" => Atom.to_string(application),
             "reason" => inspect(reason)
           }
         )}
    end
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp ->
        {:ok, timestamp}

      _value ->
        configuration_error("Baseline clock must return a DateTime", %{"field" => "clock"})
    end
  rescue
    exception ->
      configuration_error("Baseline clock raised", %{"exception" => exception_name(exception)})
  end

  defp check_availability(provider, options, baseline_plan) do
    checker = Keyword.get(options, :availability_checker, &ModelAvailability.check/3)

    result =
      safe_availability_check(
        checker,
        provider,
        baseline_plan["model"],
        availability_options(options)
      )

    case result do
      {:ok, availability} -> validate_availability(availability, baseline_plan)
      {:error, error} when is_map(error) -> {:error, error}
      other -> invalid_availability_result(other)
    end
  end

  defp availability_options(options) do
    provider_options = Keyword.get(options, :provider_options, [])

    [environment: Keyword.get_lazy(options, :environment, &System.get_env/0)]
    |> put_if_present(:api_key, provider_options)
    |> put_if_present(:req_options, provider_options)
  end

  defp put_if_present(options, key, source) do
    case Keyword.fetch(source, key) do
      {:ok, value} -> Keyword.put(options, key, value)
      :error -> options
    end
  end

  defp safe_availability_check(checker, provider, model, options) do
    checker.(provider, model, options)
  rescue
    exception ->
      {:error,
       Provider.error(:model_availability_exception, "The model availability check raised",
         details: %{
           "attempts" => 1,
           "exception" => exception_name(exception),
           "reason" => safe_exception_message(exception, options)
         }
       )}
  catch
    kind, _reason ->
      {:error,
       Provider.error(:model_availability_exception, "The model availability check terminated",
         details: %{"attempts" => 1, "kind" => Atom.to_string(kind)}
       )}
  end

  defp validate_availability(availability, baseline_plan) when is_map(availability) do
    expected = %{
      "provider" => baseline_plan["provider"],
      "requested_model" => baseline_plan["model"],
      "returned_model" => baseline_plan["model"],
      "attempts" => 1
    }

    matches? = Enum.all?(expected, fn {key, value} -> availability[key] == value end)

    cond do
      not Validation.json_value?(availability) ->
        invalid_availability_result(availability)

      not matches? ->
        {:error,
         Provider.error(
           :model_unavailable,
           "Model access did not match the requested provider and model",
           details: %{
             "expected" => expected,
             "actual" => availability
           }
         )}

      true ->
        {:ok, availability}
    end
  end

  defp validate_availability(availability, _baseline_plan),
    do: invalid_availability_result(availability)

  defp invalid_availability_result(result) do
    {:error,
     Provider.error(
       :model_availability_contract_error,
       "The model availability check returned an invalid result",
       details: %{"result" => result_identity(result)}
     )}
  end

  defp result_identity({tag, _value}) when is_atom(tag), do: Atom.to_string(tag)
  defp result_identity(result) when is_atom(result), do: Atom.to_string(result)
  defp result_identity(_result), do: "unknown"

  defp run_generation(cases, provider, options, baseline_plan) do
    generation_options =
      options
      |> runner_options(baseline_plan["max_calls"] - @availability_calls)
      |> Keyword.put(:dry_run, false)

    Runner.run(cases, provider, generation_options)
  end

  defp build_totals(baseline_plan, runner_totals, samples, metrics) do
    success_totals = RunAnalysis.success_totals(samples)
    completion = metrics["overall"]["completion"]
    quality = metrics["overall"]["quality"]

    %{
      "planned_samples" => baseline_plan["planned_samples"],
      "planned_calls" => baseline_plan["planned_calls"],
      "maximum_calls" => baseline_plan["maximum_calls"],
      "actual_calls" => runner_totals["actual_calls"] + @availability_calls,
      "availability_calls" => @availability_calls,
      "generation_calls" => runner_totals["actual_calls"],
      "successful_samples" => runner_totals["successful_samples"],
      "failed_samples" => runner_totals["failed_samples"],
      "completed_samples" => completion["completed_samples"],
      "incomplete_samples" => completion["incomplete_samples"],
      "unknown_completion_samples" => completion["unknown_samples"],
      "quality_passed_samples" => quality["passed_samples"],
      "quality_failed_samples" => quality["failed_samples"],
      "latency_ms" => success_totals["latency_ms"],
      "input_tokens" => success_totals["input_tokens"],
      "output_tokens" => success_totals["output_tokens"],
      "returned_models" => success_totals["returned_models"]
    }
  end

  defp build_run(
         baseline_plan,
         availability,
         cases,
         samples,
         metrics,
         totals,
         started_at,
         completed_at
       ) do
    request_config =
      baseline_plan["request_config"]
      |> Map.put("model_availability", availability)
      |> Map.put("samples_per_case", baseline_plan["samples_per_case"])

    Run.new(%{
      run_id: baseline_plan["run_id"],
      label: baseline_plan["label"],
      condition: baseline_plan["condition"],
      started_at: started_at,
      completed_at: completed_at,
      git_revision: baseline_plan["git_revision"],
      provider: baseline_plan["provider"],
      request_config: request_config,
      cases: cases,
      samples: samples,
      metrics: metrics,
      totals: totals
    })
  end

  defp exception_name(%{__struct__: module}) when is_atom(module), do: inspect(module)

  defp safe_exception_message(exception, options) do
    options
    |> sensitive_values()
    |> Enum.reduce(Exception.message(exception), fn sensitive_value, message ->
      String.replace(message, sensitive_value, "[REDACTED]")
    end)
  end

  defp sensitive_values(options) do
    environment = Keyword.get(options, :environment, %{})

    [
      Keyword.get(options, :api_key),
      environment["OPENAI_API_KEY"],
      environment["ANTHROPIC_API_KEY"]
    ]
    |> Enum.filter(&non_empty_string?/1)
    |> Enum.uniq()
  end

  defp configuration_error(message, details) do
    {:error, Provider.error(:configuration_error, message, details: details)}
  end
end
