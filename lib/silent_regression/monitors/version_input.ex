defmodule SilentRegression.Monitors.VersionInput do
  @moduledoc false

  alias SilentRegression.Monitors.{
    CaseInput,
    Fingerprint,
    GenerationConfig,
    JsonValue,
    Limits,
    ModelCatalog
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
         {:ok, response_format} <- response_format(attributes),
         {:ok, generation_config} <-
           GenerationConfig.normalize(Map.get(attributes, "generation_config")),
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

  defp response_format(attributes) do
    value = Map.get(attributes, "response_format", %{"type" => "text"})

    with true <- is_map(value),
         {:ok, normalized} <- JsonValue.normalize(value),
         {:ok, normalized} <- normalize_response_format(normalized),
         {:ok, size} <- JsonValue.encoded_size(normalized),
         true <- size <= Limits.fetch!(:max_response_format_bytes) do
      {:ok, normalized}
    else
      _reason -> {:error, %{field: :response_format, reason: :invalid}}
    end
  end

  defp normalize_response_format(%{"type" => type} = format)
       when type in ["text", "json_object"] do
    if Map.keys(format) == ["type"], do: {:ok, format}, else: {:error, :unknown_field}
  end

  defp normalize_response_format(
         %{
           "type" => "json_schema",
           "name" => name,
           "schema" => schema
         } = format
       )
       when is_binary(name) and is_map(schema) do
    if Map.keys(format) -- ~w(name schema strict type) == [] and
         String.trim(name) != "" and byte_size(name) <= 80 and
         Map.get(format, "strict", true) in [true, false] do
      {:ok, Map.put_new(format, "strict", true)}
    else
      {:error, :invalid_json_schema}
    end
  end

  defp normalize_response_format(_format), do: {:error, :invalid_response_format}
end
