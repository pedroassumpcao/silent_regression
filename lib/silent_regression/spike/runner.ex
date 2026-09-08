defmodule SilentRegression.Spike.Runner do
  @moduledoc """
  Plans and executes bounded provider calls for the feasibility spike.

  A run reserves the maximum possible call count before it starts: one initial
  call per sample plus the configured retry allowance for every sample. This
  makes the global call cap enforceable even though retries happen inside each
  provider client and samples execute concurrently.

  Dry runs perform the same validation and budgeting as live runs but never
  invoke the provider. Runtime-only options such as API keys, HTTP adapters,
  and test callbacks are never copied into the printable plan.
  """

  alias SilentRegression.Spike.Case
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.Validation

  @default_max_concurrency 3
  @maximum_concurrency 32
  @maximum_retries 5
  @behavior_option_keys [
    :max_output_tokens,
    :reasoning,
    :stop_sequences,
    :temperature,
    :text,
    :top_k,
    :top_p
  ]
  @request_provenance_keys ~w(api_endpoint api_version http_method)
  @minimum_output_tokens_by_case %{"rag_open_synthesis" => 512}
  @allowed_options [
    :dry_run,
    :environment,
    :max_calls,
    :max_concurrency,
    :max_retries,
    :model,
    :provider_options,
    :samples_per_case
  ]

  @type plan :: %{required(String.t()) => term()}
  @type result :: %{required(String.t()) => term()}

  @spec plan([Case.t()], module(), keyword()) :: {:ok, plan()} | {:error, Provider.error()}
  def plan(cases, provider, options) do
    with :ok <- validate_options(options),
         {:ok, provider_id} <- validate_provider(provider),
         {:ok, request_provenance} <- request_provenance(provider),
         {:ok, validated_cases} <- validate_cases(cases),
         {:ok, config} <- build_config(options),
         :ok <- validate_case_output_budget(validated_cases, config.provider_options),
         {:ok, credential} <- validate_credential(provider_id, config.environment),
         {:ok, call_budget} <- build_call_budget(validated_cases, config),
         {:ok, request_config} <- build_request_config(config, request_provenance) do
      {:ok,
       %{
         "provider" => provider_id,
         "model" => config.model,
         "cases" => Enum.map(validated_cases, &case_summary/1),
         "case_count" => length(validated_cases),
         "samples_per_case" => config.samples_per_case,
         "planned_samples" => call_budget.planned_calls,
         "planned_calls" => call_budget.planned_calls,
         "retry_calls_reserved" => call_budget.retry_calls_reserved,
         "maximum_calls" => call_budget.maximum_calls,
         "max_calls" => config.max_calls,
         "max_retries" => config.max_retries,
         "max_concurrency" => config.max_concurrency,
         "credential" => credential,
         "request_config" => request_config
       }}
    end
  end

  @spec run([Case.t()], module(), keyword()) :: {:ok, result()} | {:error, Provider.error()}
  def run(cases, provider, options) do
    with {:ok, run_plan} <- plan(cases, provider, options) do
      if Keyword.get(options, :dry_run, false) do
        {:ok, dry_run_result(run_plan)}
      else
        execute(cases, provider, options, run_plan)
      end
    end
  end

  defp validate_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)
      unsupported_options = keys -- @allowed_options

      cond do
        Enum.uniq(keys) != keys ->
          configuration_error("Runner options contain duplicate keys", %{"field" => "options"})

        unsupported_options != [] ->
          configuration_error("Runner options contain unsupported keys", %{
            "unsupported_options" => Enum.map(unsupported_options, &Atom.to_string/1)
          })

        true ->
          :ok
      end
    else
      configuration_error("Runner options must be a keyword list", %{"field" => "options"})
    end
  end

  defp validate_options(_options) do
    configuration_error("Runner options must be a keyword list", %{"field" => "options"})
  end

  defp validate_provider(provider) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :id, 0) and
         function_exported?(provider, :request_provenance, 0) and
         function_exported?(provider, :complete, 2) do
      case provider.id() do
        provider_id when is_binary(provider_id) ->
          if String.valid?(provider_id) and String.trim(provider_id) != "" do
            {:ok, provider_id}
          else
            invalid_provider()
          end

        _provider_id ->
          invalid_provider()
      end
    else
      invalid_provider()
    end
  rescue
    _error -> invalid_provider()
  end

  defp validate_provider(_provider), do: invalid_provider()

  defp invalid_provider do
    configuration_error("Provider must implement id/0, request_provenance/0, and complete/2", %{
      "field" => "provider"
    })
  end

  defp request_provenance(provider) do
    provenance = provider.request_provenance()

    if is_map(provenance) and Enum.sort(Map.keys(provenance)) == @request_provenance_keys and
         Enum.all?(@request_provenance_keys, &valid_provenance_value?(provenance[&1])) do
      {:ok, provenance}
    else
      configuration_error("Provider request provenance is invalid", %{
        "field" => "request_provenance",
        "required_keys" => @request_provenance_keys
      })
    end
  rescue
    _error ->
      configuration_error("Provider request provenance is invalid", %{
        "field" => "request_provenance",
        "required_keys" => @request_provenance_keys
      })
  end

  defp valid_provenance_value?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp valid_provenance_value?(_value), do: false

  defp validate_cases(cases) when is_list(cases) and cases != [] do
    with :ok <- validate_each_case(cases),
         :ok <- validate_unique_case_ids(cases) do
      {:ok, cases}
    end
  end

  defp validate_cases(_cases) do
    configuration_error("Cases must be a non-empty list", %{"field" => "cases"})
  end

  defp validate_each_case(cases) do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%Case{} = case_definition, index}, :ok ->
        case Case.validate(case_definition) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt,
             configuration_error("Runner received an invalid case", %{
               "field" => "cases",
               "index" => index,
               "reason" => inspect(reason)
             })}
        end

      {_case_definition, index}, :ok ->
        {:halt,
         configuration_error("Runner expected spike case definitions", %{
           "field" => "cases",
           "index" => index
         })}
    end)
  end

  defp validate_unique_case_ids(cases) do
    case_ids = Enum.map(cases, & &1.id)

    if Enum.uniq(case_ids) == case_ids do
      :ok
    else
      configuration_error("Runner case IDs must be unique", %{"field" => "cases"})
    end
  end

  defp validate_case_output_budget(cases, provider_options) do
    requirements =
      cases
      |> Enum.flat_map(fn case_definition ->
        case Map.fetch(@minimum_output_tokens_by_case, case_definition.id) do
          {:ok, minimum} -> [{case_definition.id, minimum}]
          :error -> []
        end
      end)

    minimum = requirements |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    configured = Keyword.get(provider_options, :max_output_tokens)

    if minimum == 0 or (is_integer(configured) and configured >= minimum) do
      :ok
    else
      configuration_error("Selected cases require a larger output-token budget", %{
        "field" => "provider_options.max_output_tokens",
        "actual" => configured,
        "minimum" => minimum,
        "case_ids" => Enum.map(requirements, &elem(&1, 0))
      })
    end
  end

  defp build_config(options) do
    with {:ok, model} <- required_non_empty_string(options, :model),
         {:ok, samples_per_case} <- positive_integer(options, :samples_per_case, 1),
         {:ok, max_calls} <- required_positive_integer(options, :max_calls),
         {:ok, max_retries} <- bounded_integer(options, :max_retries, 0, @maximum_retries),
         {:ok, max_concurrency} <-
           bounded_integer(
             options,
             :max_concurrency,
             @default_max_concurrency,
             @maximum_concurrency,
             minimum: 1
           ),
         {:ok, dry_run} <- boolean_option(options, :dry_run, false),
         {:ok, provider_options} <- provider_options(options),
         {:ok, environment} <- environment(options) do
      {:ok,
       %{
         model: model,
         samples_per_case: samples_per_case,
         max_calls: max_calls,
         max_retries: max_retries,
         max_concurrency: max_concurrency,
         dry_run: dry_run,
         provider_options: provider_options,
         environment: environment
       }}
    end
  end

  defp required_non_empty_string(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "" do
          {:ok, value}
        else
          missing_required_option(name)
        end

      {:ok, _value} ->
        configuration_error("Runner #{name} must be a non-empty string", %{
          "field" => Atom.to_string(name)
        })

      :error ->
        missing_required_option(name)
    end
  end

  defp required_positive_integer(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, _value} ->
        configuration_error("Runner #{name} must be a positive integer", %{
          "field" => Atom.to_string(name)
        })

      :error ->
        missing_required_option(name)
    end
  end

  defp missing_required_option(name) do
    configuration_error("Runner #{name} is required", %{
      "field" => Atom.to_string(name)
    })
  end

  defp positive_integer(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      configuration_error("Runner #{name} must be a positive integer", %{
        "field" => Atom.to_string(name)
      })
    end
  end

  defp bounded_integer(options, name, default, maximum, extra_options \\ []) do
    minimum = Keyword.get(extra_options, :minimum, 0)
    value = Keyword.get(options, name, default)

    if is_integer(value) and value >= minimum and value <= maximum do
      {:ok, value}
    else
      configuration_error("Runner #{name} must be between #{minimum} and #{maximum}", %{
        "field" => Atom.to_string(name),
        "minimum" => minimum,
        "maximum" => maximum
      })
    end
  end

  defp boolean_option(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_boolean(value) do
      {:ok, value}
    else
      configuration_error("Runner #{name} must be a boolean", %{
        "field" => Atom.to_string(name)
      })
    end
  end

  defp provider_options(options) do
    provider_options = Keyword.get(options, :provider_options, [])

    cond do
      not Keyword.keyword?(provider_options) ->
        configuration_error("Runner provider_options must be a keyword list", %{
          "field" => "provider_options"
        })

      Enum.uniq(Keyword.keys(provider_options)) != Keyword.keys(provider_options) ->
        configuration_error("Runner provider_options contain duplicate keys", %{
          "field" => "provider_options"
        })

      Keyword.has_key?(provider_options, :model) or
          Keyword.has_key?(provider_options, :max_retries) ->
        configuration_error("Runner owns model and retry configuration", %{
          "field" => "provider_options"
        })

      true ->
        {:ok, provider_options}
    end
  end

  defp environment(options) do
    environment = Keyword.get_lazy(options, :environment, &System.get_env/0)

    if is_map(environment) do
      {:ok, environment}
    else
      configuration_error("Runner environment must be a map", %{"field" => "environment"})
    end
  end

  defp validate_credential(provider_id, environment) do
    case credential_env_var(provider_id) do
      nil ->
        {:ok, %{"required" => false, "env_var" => nil, "present" => true}}

      env_var ->
        if credential_present?(environment[env_var]) do
          {:ok, %{"required" => true, "env_var" => env_var, "present" => true}}
        else
          configuration_error("Required provider credential is missing", %{
            "field" => "environment",
            "env_var" => env_var
          })
        end
    end
  end

  defp credential_env_var("openai"), do: "OPENAI_API_KEY"
  defp credential_env_var("anthropic"), do: "ANTHROPIC_API_KEY"
  defp credential_env_var(_provider_id), do: nil

  defp credential_present?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp credential_present?(_value), do: false

  defp build_call_budget(cases, config) do
    planned_calls = length(cases) * config.samples_per_case
    retry_calls_reserved = planned_calls * config.max_retries
    maximum_calls = planned_calls + retry_calls_reserved

    if maximum_calls <= config.max_calls do
      {:ok,
       %{
         planned_calls: planned_calls,
         retry_calls_reserved: retry_calls_reserved,
         maximum_calls: maximum_calls
       }}
    else
      {:error,
       Provider.error(
         :call_budget_exceeded,
         "Planned calls and retry reserve exceed the max-calls cap",
         details: %{
           "planned_calls" => planned_calls,
           "retry_calls_reserved" => retry_calls_reserved,
           "maximum_calls" => maximum_calls,
           "max_calls" => config.max_calls
         }
       )}
    end
  end

  defp build_request_config(config, request_provenance) do
    config.provider_options
    |> Keyword.take(@behavior_option_keys)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, request_config} ->
      if Validation.json_value?(value) do
        {:cont, {:ok, Map.put(request_config, Atom.to_string(key), value)}}
      else
        {:halt,
         configuration_error("Runner behavior options must be JSON-compatible", %{
           "field" => "provider_options",
           "option" => Atom.to_string(key)
         })}
      end
    end)
    |> case do
      {:ok, behavior_options} ->
        {:ok,
         request_provenance
         |> Map.merge(behavior_options)
         |> Map.put("model", config.model)
         |> Map.put("max_retries", config.max_retries)}

      {:error, _error} = failure ->
        failure
    end
  end

  defp case_summary(case_definition) do
    %{
      "id" => case_definition.id,
      "version" => case_definition.version,
      "fingerprint" => case_definition.fingerprint
    }
  end

  defp dry_run_result(run_plan) do
    %{
      "status" => "dry_run",
      "plan" => run_plan,
      "samples" => [],
      "totals" => totals(run_plan, [], 0)
    }
  end

  defp execute(cases, provider, options, run_plan) do
    jobs = build_jobs(cases, run_plan["samples_per_case"])
    provider_options = completion_options(options, run_plan)

    samples =
      jobs
      |> Task.async_stream(
        &execute_job(&1, provider, provider_options),
        max_concurrency: run_plan["max_concurrency"],
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(&unwrap_task_result/1)

    actual_calls = Enum.reduce(samples, 0, fn sample, total -> total + sample["attempts"] end)

    if actual_calls <= run_plan["max_calls"] do
      {:ok,
       %{
         "status" => "completed",
         "plan" => run_plan,
         "samples" => samples,
         "totals" => totals(run_plan, samples, actual_calls)
       }}
    else
      {:error,
       Provider.error(:call_budget_exceeded, "Provider attempts exceeded the max-calls cap",
         details: %{
           "actual_calls" => actual_calls,
           "max_calls" => run_plan["max_calls"]
         }
       )}
    end
  end

  defp build_jobs(cases, samples_per_case) do
    for case_definition <- cases,
        sample_index <- 0..(samples_per_case - 1) do
      %{
        case_definition: case_definition,
        sample_index: sample_index
      }
    end
  end

  defp completion_options(options, run_plan) do
    options
    |> Keyword.get(:provider_options, [])
    |> Keyword.put(:model, run_plan["model"])
    |> Keyword.put(:max_retries, run_plan["max_retries"])
  end

  defp execute_job(job, provider, provider_options) do
    provider_result = safe_complete(provider, job.case_definition, provider_options)

    case provider_result do
      {:ok, %Response{} = response} ->
        success_sample(job, response)

      {:error, error} when is_map(error) ->
        failure_sample(job, error, error_attempts(error))

      other ->
        failure_sample(job, provider_contract_error(other), 1)
    end
  end

  defp safe_complete(provider, case_definition, provider_options) do
    provider.complete(case_definition, provider_options)
  rescue
    exception ->
      {:error,
       Provider.error(:provider_exception, "Provider raised while completing a sample",
         details: %{"attempts" => 1, "exception" => exception_name(exception)}
       )}
  catch
    kind, _reason ->
      {:error,
       Provider.error(:provider_exception, "Provider terminated while completing a sample",
         details: %{"attempts" => 1, "kind" => Atom.to_string(kind)}
       )}
  end

  defp success_sample(job, response) do
    case Response.validate(response) do
      :ok ->
        sample_identity(job)
        |> Map.put("status", "ok")
        |> Map.put("attempts", response.attempts)
        |> Map.put("response", Response.to_map(response))

      {:error, reason} ->
        failure_sample(job, invalid_response_error(reason), response_attempts(response))
    end
  end

  defp failure_sample(job, error, attempts) do
    sample_identity(job)
    |> Map.put("status", "error")
    |> Map.put("attempts", attempts)
    |> Map.put("error", error)
  end

  defp sample_identity(job) do
    %{
      "case_id" => job.case_definition.id,
      "case_fingerprint" => job.case_definition.fingerprint,
      "sample_index" => job.sample_index
    }
  end

  defp error_attempts(error) do
    case get_in(error, ["details", "attempts"]) do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _attempts -> 0
    end
  end

  defp response_attempts(%Response{attempts: attempts})
       when is_integer(attempts) and attempts > 0,
       do: attempts

  defp response_attempts(_response), do: 1

  defp provider_contract_error(result) do
    Provider.error(:provider_contract_error, "Provider returned an invalid result",
      details: %{"result" => result_identity(result)}
    )
  end

  defp result_identity({tag, _value}) when is_atom(tag), do: Atom.to_string(tag)
  defp result_identity(result) when is_atom(result), do: Atom.to_string(result)
  defp result_identity(_result), do: "unknown"

  defp invalid_response_error(reason) do
    Provider.error(:provider_contract_error, "Provider returned an invalid response",
      details: %{"reason" => inspect(reason)}
    )
  end

  defp exception_name(%{__struct__: module}) when is_atom(module), do: inspect(module)

  defp unwrap_task_result({:ok, sample}), do: sample

  defp unwrap_task_result({:exit, reason}) do
    %{
      "case_id" => "unknown",
      "case_fingerprint" => nil,
      "sample_index" => -1,
      "status" => "error",
      "attempts" => 0,
      "error" =>
        Provider.error(:runner_task_exit, "A runner task exited unexpectedly",
          details: %{"reason" => inspect(reason)}
        )
    }
  end

  defp totals(run_plan, samples, actual_calls) do
    successful_samples = Enum.count(samples, &(&1["status"] == "ok"))
    failed_samples = Enum.count(samples, &(&1["status"] == "error"))

    %{
      "planned_samples" => run_plan["planned_samples"],
      "planned_calls" => run_plan["planned_calls"],
      "maximum_calls" => run_plan["maximum_calls"],
      "actual_calls" => actual_calls,
      "successful_samples" => successful_samples,
      "failed_samples" => failed_samples
    }
  end

  defp configuration_error(message, details) do
    {:error, Provider.error(:configuration_error, message, details: details)}
  end
end
