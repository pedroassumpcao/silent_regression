defmodule SilentRegression.Monitors.VersionInput do
  @moduledoc false

  alias SilentRegression.Monitors.{
    CaseInput,
    Fingerprint,
    GenerationConfig,
    JsonValue,
    Limits,
    ModelCatalog,
    ResponseFormat
  }

  @keys ~w(provider requested_model system_prompt user_prompt_template response_format generation_config)

  def normalize(attributes) when is_map(attributes) do
    with {:ok, cases, attributes} <- extract_cases(attributes),
         {:ok, attributes} <- JsonValue.normalize(attributes),
         [] <- Map.keys(attributes) -- @keys,
         {:ok, {provider, requested_model}} <- provider_model(attributes),
         {:ok, system_prompt} <- prompt(attributes, "system_prompt", :system_prompt, false),
         {:ok, user_prompt_template} <-
           prompt(attributes, "user_prompt_template", :user_prompt_template, true),
         {:ok, response_format} <-
           ResponseFormat.normalize(Map.get(attributes, "response_format")),
         {:ok, generation_config} <-
           GenerationConfig.normalize(Map.get(attributes, "generation_config")),
         :ok <-
           ModelCatalog.validate_generation_config(
             provider,
             requested_model,
             generation_config
           ),
         {:ok, cases} <- CaseInput.normalize_many(cases) do
      normalized = %{
        schema_version: Limits.fetch!(:schema_version),
        provider: provider,
        requested_model: requested_model,
        system_prompt: system_prompt,
        user_prompt_template: user_prompt_template,
        response_format: response_format,
        generation_config: generation_config,
        cases: cases,
        case_set_fingerprint: Fingerprint.case_set_digest(cases)
      }

      {:ok, Map.put(normalized, :fingerprint, Fingerprint.monitor_version_digest(normalized))}
    else
      {:error, reason} -> {:error, reason}
      _reason -> {:error, %{field: :configuration, reason: :invalid}}
    end
  end

  def normalize(_attributes),
    do: {:error, %{field: :configuration, reason: :invalid}}

  defp extract_cases(attributes) do
    case {Map.fetch(attributes, :cases), Map.fetch(attributes, "cases")} do
      {{:ok, _atom_cases}, {:ok, _string_cases}} ->
        {:error, :invalid_json_value}

      {{:ok, cases}, :error} ->
        {:ok, cases, Map.delete(attributes, :cases)}

      {:error, {:ok, cases}} ->
        {:ok, cases, Map.delete(attributes, "cases")}

      {:error, :error} ->
        {:ok, nil, attributes}
    end
  end

  defp provider_model(attributes) do
    case ModelCatalog.validate(
           Map.get(attributes, "provider"),
           Map.get(attributes, "requested_model")
         ) do
      {:ok, pair} -> {:ok, pair}
      {:error, reason} -> {:error, %{field: :requested_model, reason: reason}}
    end
  end

  defp prompt(attributes, field, field_atom, required?) do
    value = Map.get(attributes, field, "")

    if is_binary(value) and String.valid?(value) and
         byte_size(value) <= Limits.fetch!(:max_prompt_bytes) and
         (not required? or String.trim(value) != "") do
      {:ok, value}
    else
      {:error, %{field: field_atom, reason: :invalid}}
    end
  end
end
