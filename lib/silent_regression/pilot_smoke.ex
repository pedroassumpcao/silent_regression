defmodule SilentRegression.PilotSmoke do
  @moduledoc """
  Preview-first, fixed-content provider transport smoke checks for pilot readiness.

  This boundary deliberately supports one case, one sample, no retry, and one
  provider call. It is operator tooling rather than a customer monitoring run.
  """

  import Ecto.Query

  alias SilentRegression.Contracts.Evaluator
  alias SilentRegression.Monitors.ModelCatalog
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Providers

  alias SilentRegression.Providers.{
    CompletionRequest,
    CompletionResult,
    Failure,
    RequestArtifact
  }

  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.Workspace

  @case_key "provider_transport_smoke"
  @system_prompt "Return exactly the single lowercase word approved."
  @context "This is a bounded provider transport smoke test."
  @user_prompt "Reply with exactly approved."
  @response_format %{"type" => "text"}
  @generation_config %{"max_output_tokens" => 16}
  @contract %{
    "id" => "smoke_contract",
    "type" => "classification",
    "allowed_values" => ["approved"]
  }

  @spec preview(keyword()) :: {:ok, map()} | {:error, atom()}
  def preview(options) when is_list(options) do
    with {:ok, workspace_slug} <- required_string(options, :workspace_slug),
         {:ok, provider} <- cast_provider(Keyword.get(options, :provider)),
         {:ok, model} <- required_string(options, :model),
         {:ok, {^provider, ^model}} <- ModelCatalog.validate(provider, model),
         {:ok, credential_id} <- cast_credential_id(Keyword.get(options, :credential_id)),
         %{id: ^credential_id} = credential <-
           load_credential_metadata(workspace_slug, provider, credential_id),
         {:ok, built} <- smoke_request_artifact(provider, model) do
      plan = %{
        fingerprint_schema: "provider-smoke-v2",
        workspace_slug: workspace_slug,
        provider: provider,
        model: model,
        credential_id: credential.id,
        credential_label: credential.label,
        credential_suffix: credential.secret_suffix,
        case_key: @case_key,
        case_count: 1,
        samples_per_case: 1,
        retry_limit: 0,
        planned_call_count: 1,
        maximum_call_count: 1,
        system_prompt: @system_prompt,
        context: @context,
        user_prompt: @user_prompt,
        response_format: @response_format,
        generation_config: @generation_config,
        request_mode: built.mode,
        request_schema_version: built.schema_version,
        request_artifact: built.artifact,
        request_fingerprint: built.fingerprint,
        contract: @contract
      }

      {:ok, Map.put(plan, :preview_fingerprint, fingerprint(plan))}
    else
      nil -> {:error, :credential_not_found}
      {:error, :model_not_allowed} -> {:error, :model_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  def preview(_options), do: {:error, :invalid_options}

  @spec execute(map()) :: {:ok, map()} | {:error, map() | atom()}
  def execute(%{preview_fingerprint: expected_fingerprint} = plan) do
    with true <- expected_fingerprint == fingerprint(Map.delete(plan, :preview_fingerprint)),
         %ProviderCredential{} = credential <-
           load_credential(plan.workspace_slug, plan.provider, plan.credential_id),
         request <- completion_request(plan),
         result <- Providers.complete_once(plan.provider, credential.secret, request),
         {:ok, summary} <- summarize(result, plan) do
      {:ok, summary}
    else
      false -> {:error, :preview_changed}
      nil -> {:error, :credential_not_found}
      {:error, %Failure{} = failure} -> {:error, failure_summary(failure)}
      {:error, summary} -> {:error, summary}
    end
  end

  def execute(_plan), do: {:error, :invalid_preview}

  defp completion_request(plan) do
    %CompletionRequest{
      case_id: @case_key,
      attempt_number: 1,
      requested_model: plan.model,
      request_mode: plan.request_mode,
      request_schema_version: plan.request_schema_version,
      request_artifact: plan.request_artifact,
      request_fingerprint: plan.request_fingerprint,
      client_request_id: "pilot-smoke-#{Ecto.UUID.generate()}"
    }
  end

  defp smoke_request_artifact(provider, model) do
    configuration = %{
      provider: provider,
      requested_model: model,
      request_mode: :provider_native_v1,
      request_schema_version: RequestArtifact.request_schema_version(),
      request_template: smoke_template(provider),
      system_prompt: "",
      user_prompt_template: "",
      response_format: @response_format,
      generation_config: @generation_config
    }

    RequestArtifact.build(configuration, %{
      input_variables: %{"question" => @user_prompt},
      frozen_context: @context
    })
  end

  defp smoke_template(:openai) do
    %{
      "instructions" => @system_prompt,
      "input" => [
        %{"role" => "user", "content" => "{{frozen_context}}\n\n{{question}}"}
      ]
    }
  end

  defp smoke_template(:anthropic) do
    %{
      "system" => @system_prompt,
      "messages" => [
        %{"role" => "user", "content" => "{{frozen_context}}\n\n{{question}}"}
      ]
    }
  end

  defp summarize({:ok, %CompletionResult{} = result}, plan) do
    {contract_status, _rule_results} = Evaluator.evaluate(@contract, result.output_text)
    model_match = result.requested_model == plan.model and result.returned_model == plan.model

    summary = %{
      provider: result.provider,
      requested_model: result.requested_model,
      returned_model: result.returned_model,
      model_match: model_match,
      completion_state: result.completion_state,
      contract_status: contract_status,
      actual_call_count: 1,
      attempts: 1,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      output_bytes: byte_size(result.output_text),
      latency_ms: result.latency_ms,
      request_id: result.request_id
    }

    if model_match and result.completion_state == :complete and contract_status == :pass do
      {:ok, summary}
    else
      {:error, Map.put(summary, :outcome, :failed)}
    end
  end

  defp summarize({:error, %Failure{} = failure}, _plan), do: {:error, failure}

  defp failure_summary(%Failure{} = failure) do
    %{
      outcome: :failed,
      category: failure.category,
      message: failure.message,
      request_id: failure.request_id,
      requested_model: failure.requested_model,
      actual_call_count: 1,
      attempts: failure.attempts,
      latency_ms: failure.latency_ms
    }
  end

  defp load_credential(workspace_slug, provider, credential_id) do
    workspace_slug
    |> credential_query(provider, credential_id)
    |> Repo.one()
  end

  defp load_credential_metadata(workspace_slug, provider, credential_id) do
    workspace_slug
    |> credential_query(provider, credential_id)
    |> select([credential, _workspace], %{
      id: credential.id,
      label: credential.label,
      secret_suffix: credential.secret_suffix
    })
    |> Repo.one()
  end

  defp credential_query(workspace_slug, provider, credential_id) do
    ProviderCredential
    |> join(:inner, [credential], workspace in Workspace,
      on: workspace.id == credential.workspace_id
    )
    |> where([credential, workspace], workspace.slug == ^workspace_slug)
    |> where([_credential, workspace], workspace.status == :active and workspace.alpha_access)
    |> where([credential, _workspace], credential.id == ^credential_id)
    |> where([credential, _workspace], credential.provider == ^provider)
    |> where([credential, _workspace], credential.status == :valid)
  end

  defp fingerprint(plan) do
    payload =
      {
        plan.fingerprint_schema,
        plan.workspace_slug,
        plan.provider,
        plan.model,
        plan.credential_id,
        plan.case_key,
        plan.case_count,
        plan.samples_per_case,
        plan.retry_limit,
        plan.planned_call_count,
        plan.maximum_call_count,
        plan.system_prompt,
        plan.context,
        plan.user_prompt,
        plan.response_format,
        plan.generation_config,
        plan.request_artifact,
        plan.request_fingerprint,
        plan.contract
      }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp required_string(options, key) do
    case Keyword.get(options, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" and String.valid?(value) and byte_size(value) <= 200 do
          {:ok, value}
        else
          {:error, :invalid_option}
        end

      _value ->
        {:error, :missing_option}
    end
  end

  defp cast_provider(value) when value in [:openai, "openai"], do: {:ok, :openai}
  defp cast_provider(value) when value in [:anthropic, "anthropic"], do: {:ok, :anthropic}
  defp cast_provider(_value), do: {:error, :unsupported_provider}

  defp cast_credential_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_credential_id}
    end
  end
end
