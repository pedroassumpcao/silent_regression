defmodule SilentRegression.MonitorsFixtures do
  @moduledoc """
  Test helpers for workspace-scoped monitors and immutable versions.
  """

  alias SilentRegression.Monitors

  def valid_version_attributes(overrides \\ %{}) do
    defaults = %{
      provider: "openai",
      requested_model: "gpt-5.6-luna",
      system_prompt: "Answer only from the supplied context.",
      user_prompt_template: "Question: {{question}}",
      response_format: %{type: "json_object"},
      generation_config: %{max_output_tokens: 256, temperature: 0},
      cases: [
        %{
          case_key: "supported-answer",
          name: "Supported answer",
          position: 0,
          status: "active",
          input_variables: %{question: "Which plan includes SSO?"},
          frozen_context: "The Enterprise plan includes SSO."
        }
      ]
    }

    Map.merge(defaults, overrides)
  end

  def monitor_fixture(scope, attrs \\ %{}) do
    defaults = %{
      name: "Monitor #{System.unique_integer([:positive])}",
      description: "Protect a deterministic support workflow"
    }

    {:ok, monitor} = Monitors.create_monitor(scope, Map.merge(defaults, attrs))
    monitor
  end

  def version_fixture(scope, monitor, attrs \\ %{}) do
    {:ok, version} =
      Monitors.create_version(scope, monitor.id, valid_version_attributes(attrs))

    version
  end
end
