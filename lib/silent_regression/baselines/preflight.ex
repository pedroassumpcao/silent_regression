defmodule SilentRegression.Baselines.Preflight do
  @moduledoc false

  alias SilentRegression.Monitors.{Fingerprint, ModelCatalog}

  @retry_limit 1
  @default_samples 1
  @maximum_samples 5

  @enforce_keys [
    :ready?,
    :blockers,
    :monitor,
    :monitor_version,
    :contract_version,
    :credential,
    :replacement?,
    :cases,
    :samples_per_case,
    :retry_limit,
    :planned_call_count,
    :maximum_call_count,
    :call_cap,
    :remaining_call_capacity,
    :max_output_tokens_per_call,
    :maximum_output_tokens,
    :preview_fingerprint
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  def build(resources, samples_per_case, call_cap) do
    cases = active_cases(resources.monitor_version)
    planned_call_count = length(cases) * samples_per_case
    maximum_call_count = planned_call_count * (@retry_limit + 1)
    max_output_tokens = max_output_tokens(resources.monitor_version)

    blockers =
      resources
      |> blockers(cases, maximum_call_count, call_cap)
      |> Enum.uniq_by(& &1.code)

    fingerprint =
      preview_fingerprint(
        resources,
        cases,
        samples_per_case,
        planned_call_count,
        maximum_call_count,
        max_output_tokens
      )

    %__MODULE__{
      ready?: blockers == [],
      blockers: blockers,
      monitor: resources.monitor,
      monitor_version: resources.monitor_version,
      contract_version: resources.contract_version,
      credential: resources.credential,
      replacement?: resources.replacement_baseline?,
      cases: cases,
      samples_per_case: samples_per_case,
      retry_limit: @retry_limit,
      planned_call_count: planned_call_count,
      maximum_call_count: maximum_call_count,
      call_cap: call_cap,
      remaining_call_capacity: max(call_cap - maximum_call_count, 0),
      max_output_tokens_per_call: max_output_tokens,
      maximum_output_tokens: max_output_tokens * maximum_call_count,
      preview_fingerprint: fingerprint
    }
  end

  def default_samples, do: @default_samples
  def maximum_samples, do: @maximum_samples
  def retry_limit, do: @retry_limit

  def cast_samples(nil), do: {:ok, @default_samples}
  def cast_samples(""), do: {:ok, @default_samples}

  def cast_samples(value)
      when is_integer(value) and value >= 1 and value <= @maximum_samples,
      do: {:ok, value}

  def cast_samples(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> cast_samples(parsed)
      _other -> {:error, :invalid_samples_per_case}
    end
  end

  def cast_samples(_value), do: {:error, :invalid_samples_per_case}

  defp blockers(resources, cases, maximum_call_count, call_cap) do
    []
    |> require(resources.monitor, "monitor_not_found", "The monitor is unavailable.")
    |> require_monitor_state(resources)
    |> require(
      resources.monitor_version,
      "configuration_missing",
      "Complete monitor setup first."
    )
    |> require_version_state(resources.monitor_version)
    |> require_allowed_model(resources.monitor_version)
    |> require_supported_generation_config(resources.monitor_version)
    |> require(cases != [], "cases_missing", "Add at least one active case.")
    |> require(
      resources.contract_version,
      "contract_not_approved",
      "Approve a deterministic contract for this configuration first."
    )
    |> require(
      resources.credential,
      "credential_unavailable",
      "Select a valid provider credential."
    )
    |> require_credential_provider(resources.credential, resources.monitor_version)
    |> require_model_access(resources.credential, resources.monitor_version)
    |> require(
      maximum_call_count <= call_cap,
      "call_cap_exceeded",
      "Reduce samples so the capture fits the per-run alpha call cap."
    )
  end

  defp require(blockers, value, code, message) do
    if value, do: blockers, else: blockers ++ [%{code: code, message: message}]
  end

  defp require_monitor_state(blockers, %{monitor: nil}), do: blockers

  defp require_monitor_state(blockers, resources) do
    monitor = resources.monitor

    replacement_state? =
      resources.replacement_baseline? and
        (monitor.state == :active or
           (monitor.state == :paused and monitor.pause_reason == :incompatible_configuration))

    require(
      blockers,
      monitor.state in [:draft, :validating, :ready, :baseline_pending] or replacement_state?,
      "monitor_state_invalid",
      "This monitor cannot start a baseline from its current state."
    )
  end

  defp require_version_state(blockers, nil), do: blockers

  defp require_version_state(blockers, version) do
    require(
      blockers,
      version.status in [:draft, :active],
      "configuration_not_current",
      "The contract-approved configuration is no longer current."
    )
  end

  defp require_allowed_model(blockers, nil), do: blockers

  defp require_allowed_model(blockers, version) do
    require(
      blockers,
      match?({:ok, _pair}, ModelCatalog.validate(version.provider, version.requested_model)),
      "model_not_allowed",
      "The configured model is no longer available for new captures."
    )
  end

  defp require_supported_generation_config(blockers, nil), do: blockers

  defp require_supported_generation_config(blockers, version) do
    require(
      blockers,
      :ok ==
        ModelCatalog.validate_generation_config(
          version.provider,
          version.requested_model,
          version.generation_config
        ),
      "generation_config_unsupported",
      "The saved generation settings are not supported by this model. Create a compatible configuration before capture."
    )
  end

  defp require_credential_provider(blockers, nil, _version), do: blockers
  defp require_credential_provider(blockers, _credential, nil), do: blockers

  defp require_credential_provider(blockers, credential, version) do
    require(
      blockers,
      credential.status == :valid and credential.provider == version.provider,
      "credential_unavailable",
      "The selected credential is not valid for this provider."
    )
  end

  defp require_model_access(blockers, nil, _version), do: blockers
  defp require_model_access(blockers, _credential, nil), do: blockers

  defp require_model_access(blockers, credential, version) do
    verified? =
      credential.status == :valid and credential.last_validation_status == :succeeded and
        credential.last_requested_model == version.requested_model and
        credential.last_returned_model == version.requested_model

    require(
      blockers,
      verified?,
      "model_access_unverified",
      "Verify access to the exact requested model before authorizing completion calls."
    )
  end

  defp active_cases(nil), do: []

  defp active_cases(version) do
    version.cases
    |> Enum.filter(&(&1.status == :active))
    |> Enum.sort_by(&{&1.position, &1.id})
  end

  defp max_output_tokens(nil), do: 0

  defp max_output_tokens(version) do
    case version.generation_config["max_output_tokens"] do
      value when is_integer(value) and value > 0 -> value
      _value -> 0
    end
  end

  defp preview_fingerprint(
         %{monitor: monitor, monitor_version: version, contract_version: contract},
         cases,
         samples_per_case,
         planned_call_count,
         maximum_call_count,
         max_output_tokens
       )
       when not is_nil(monitor) and not is_nil(version) and not is_nil(contract) do
    Fingerprint.digest(%{
      "fingerprint_schema" => "baseline-preflight-v1",
      "monitor_id" => monitor.id,
      "monitor_version_id" => version.id,
      "monitor_fingerprint" => version.fingerprint,
      "case_set_fingerprint" => version.case_set_fingerprint,
      "case_ids" => Enum.map(cases, & &1.id),
      "contract_version_id" => contract.id,
      "contract_fingerprint" => contract.fingerprint,
      "contract_semantics_fingerprint" => contract.contract_fingerprint,
      "evaluator_engine_version" => contract.evaluator_engine_version,
      "provider" => Atom.to_string(version.provider),
      "requested_model" => version.requested_model,
      "samples_per_case" => samples_per_case,
      "retry_limit" => @retry_limit,
      "planned_call_count" => planned_call_count,
      "maximum_call_count" => maximum_call_count,
      "max_output_tokens_per_call" => max_output_tokens
    })
  end

  defp preview_fingerprint(
         _resources,
         _cases,
         _samples,
         _planned,
         _maximum,
         _max_output_tokens
       ),
       do: nil
end
