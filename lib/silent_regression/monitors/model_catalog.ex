defmodule SilentRegression.Monitors.ModelCatalog do
  @moduledoc """
  Exact provider/model pairs selectable by new private-alpha monitor versions.

  Historical versions retain their requested model even after the catalog changes.
  """

  alias SilentRegression.Monitors.Limits

  @providers [:openai, :anthropic]

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

  def providers, do: @providers

  defp cast_provider(provider) when provider in @providers, do: {:ok, provider}
  defp cast_provider("openai"), do: {:ok, :openai}
  defp cast_provider("anthropic"), do: {:ok, :anthropic}
  defp cast_provider(_provider), do: {:error, :provider_not_allowed}
end
