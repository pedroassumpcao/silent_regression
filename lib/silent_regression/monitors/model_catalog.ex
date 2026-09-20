defmodule SilentRegression.Monitors.ModelCatalog do
  @moduledoc """
  Exact provider/model pairs selectable by new private-alpha monitor versions.

  Historical versions retain their requested model even after the catalog changes.
  """

  alias SilentRegression.Monitors.Limits

  @providers [:openai, :anthropic]
  @openai_reasoning_efforts ~w(none low medium high xhigh max)

  @generation_capabilities %{
    openai: %{
      "gpt-5.6-luna" => %{
        "parameters" => ~w(max_output_tokens reasoning_effort),
        "reasoning_efforts" => @openai_reasoning_efforts
      },
      "gpt-5.6-sol" => %{
        "parameters" => ~w(max_output_tokens reasoning_effort),
        "reasoning_efforts" => @openai_reasoning_efforts
      }
    },
    anthropic: %{
      "claude-haiku-4-5-20251001" => %{
        "parameters" => ~w(max_output_tokens temperature top_p),
        "reasoning_efforts" => []
      },
      "claude-sonnet-5" => %{
        "parameters" => ~w(max_output_tokens),
        "reasoning_efforts" => []
      }
    }
  }

  def all, do: Limits.fetch!(:allowed_models)

  def models(provider) do
    with {:ok, provider} <- cast_provider(provider) do
      {:ok, Map.fetch!(all(), provider)}
    end
  end

  def validate(provider, model) when is_binary(model) do
    with {:ok, provider} <- cast_provider(provider),
         model <- String.trim(model),
         true <- model in Map.fetch!(all(), provider) do
      {:ok, {provider, model}}
    else
      _reason -> {:error, :model_not_allowed}
    end
  end

  def validate(_provider, _model), do: {:error, :model_not_allowed}

  def generation_capabilities, do: @generation_capabilities

  def generation_capabilities(provider, model) do
    with {:ok, {provider, model}} <- validate(provider, model) do
      {:ok, @generation_capabilities |> Map.fetch!(provider) |> Map.fetch!(model)}
    end
  end

  def validate_generation_config(provider, model, config) when is_map(config) do
    with {:ok, capabilities} <- generation_capabilities(provider, model),
         [] <- Map.keys(config) -- capabilities["parameters"],
         :ok <- validate_reasoning_effort(config, capabilities) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      unsupported when is_list(unsupported) ->
        {:error,
         %{
           field: :generation_config,
           reason: :unsupported_parameters,
           parameters: Enum.sort(unsupported)
         }}
    end
  end

  def validate_generation_config(_provider, _model, _config) do
    {:error, %{field: :generation_config, reason: :invalid}}
  end

  def providers, do: @providers

  defp validate_reasoning_effort(config, capabilities) do
    case Map.get(config, "reasoning_effort") do
      nil ->
        :ok

      effort ->
        if effort in capabilities["reasoning_efforts"] do
          :ok
        else
          {:error,
           %{
             field: :generation_config,
             reason: :unsupported_reasoning_effort,
             reasoning_effort: effort
           }}
        end
    end
  end

  defp cast_provider(provider) when provider in @providers, do: {:ok, provider}
  defp cast_provider("openai"), do: {:ok, :openai}
  defp cast_provider("anthropic"), do: {:ok, :anthropic}
  defp cast_provider(_provider), do: {:error, :provider_not_allowed}
end
