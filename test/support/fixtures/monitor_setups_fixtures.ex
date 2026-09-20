defmodule SilentRegression.MonitorSetupsFixtures do
  @moduledoc """
  Test helpers for resumable cold-start monitor setup.
  """

  alias SilentRegression.{MonitorSetups, ProviderCredentials}
  alias SilentRegression.ProviderCredentialsFixtures

  def setup_fixture(scope, attrs \\ %{}) do
    defaults = %{
      name: "Setup monitor #{System.unique_integer([:positive])}",
      description: "Detect unsupported deterministic answers"
    }

    {:ok, result} = MonitorSetups.start(scope, Map.merge(defaults, attrs))
    result
  end

  def valid_credential_fixture(scope, attrs \\ %{}) do
    credential = ProviderCredentialsFixtures.provider_credential_fixture(scope, attrs)
    {:ok, validated} = ProviderCredentials.validate_credential(scope, credential.id)
    validated
  end

  def complete_setup_fixture(scope, attrs \\ %{}) do
    result = setup_fixture(scope, Map.get(attrs, :monitor, %{}))
    credential = valid_credential_fixture(scope, Map.get(attrs, :credential, %{}))

    {:ok, _setup} =
      MonitorSetups.update_connection(scope, result.monitor.id, %{
        provider_credential_id: credential.id,
        provider: credential.provider,
        requested_model: requested_model(credential.provider)
      })

    {:ok, _setup} =
      MonitorSetups.update_prompt(scope, result.monitor.id, %{
        request_template: request_template(credential.provider),
        response_format: response_format(credential.provider),
        generation_config: %{max_output_tokens: "256"}
      })

    default_case = %{
      case_key: "supported-answer",
      name: "Supported answer",
      input_variables_json: ~s({"question":"Which plan includes SSO?"}),
      frozen_context: "The Enterprise plan includes SSO.",
      status: "active"
    }

    {:ok, _setup} =
      MonitorSetups.update_cases(
        scope,
        result.monitor.id,
        Map.get(attrs, :cases, [default_case])
      )

    {:ok, completed} = MonitorSetups.complete(scope, result.monitor.id)
    Map.put(completed, :credential, credential)
  end

  defp requested_model(:openai), do: "gpt-5.6-luna"
  defp requested_model(:anthropic), do: "claude-haiku-4-5-20251001"

  defp request_template(:openai) do
    %{
      instructions: "Answer only from the supplied context.",
      input: [
        %{
          role: "user",
          content: "Context:\n{{frozen_context}}\n\nQuestion:\n{{question}}"
        }
      ]
    }
  end

  defp request_template(:anthropic) do
    %{
      system: "Answer only from the supplied context.",
      messages: [
        %{
          role: "user",
          content: "Context:\n{{frozen_context}}\n\nQuestion:\n{{question}}"
        }
      ]
    }
  end

  defp response_format(:openai), do: %{type: "json_object"}
  defp response_format(:anthropic), do: %{type: "text"}
end
