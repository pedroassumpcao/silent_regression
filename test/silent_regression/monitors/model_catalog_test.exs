defmodule SilentRegression.Monitors.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Monitors.ModelCatalog

  test "defines generation capabilities for every allowlisted provider/model pair" do
    capabilities = ModelCatalog.generation_capabilities()

    Enum.each(ModelCatalog.all(), fn {provider, models} ->
      assert Map.keys(Map.fetch!(capabilities, provider)) |> Enum.sort() == Enum.sort(models)
    end)
  end

  test "keeps unsupported sampling and reasoning combinations out of OpenAI requests" do
    assert {:error,
            %{
              reason: :unsupported_parameters,
              parameters: ["temperature", "top_p"]
            }} =
             ModelCatalog.validate_generation_config(:openai, "gpt-5.6-luna", %{
               "max_output_tokens" => 32,
               "temperature" => 0.0,
               "top_p" => 0.9
             })

    assert {:error, %{reason: :unsupported_reasoning_effort, reasoning_effort: "minimal"}} =
             ModelCatalog.validate_generation_config(:openai, "gpt-5.6-sol", %{
               "max_output_tokens" => 32,
               "reasoning_effort" => "minimal"
             })

    assert :ok =
             ModelCatalog.validate_generation_config(:openai, "gpt-5.6-luna", %{
               "max_output_tokens" => 32,
               "reasoning_effort" => "none"
             })
  end

  test "allows the sampling controls implemented by the Anthropic adapter" do
    assert :ok =
             ModelCatalog.validate_generation_config(
               :anthropic,
               "claude-haiku-4-5-20251001",
               %{
                 "max_output_tokens" => 32,
                 "temperature" => 0.0,
                 "top_p" => 0.9
               }
             )

    assert {:error, %{reason: :unsupported_parameters, parameters: ["reasoning_effort"]}} =
             ModelCatalog.validate_generation_config(:anthropic, "claude-sonnet-5", %{
               "max_output_tokens" => 32,
               "reasoning_effort" => "low"
             })

    assert {:error, %{reason: :unsupported_parameters, parameters: ["temperature"]}} =
             ModelCatalog.validate_generation_config(:anthropic, "claude-sonnet-5", %{
               "max_output_tokens" => 32,
               "temperature" => 0.0
             })
  end
end
