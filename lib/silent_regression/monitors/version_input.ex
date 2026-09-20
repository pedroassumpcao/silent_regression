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

  alias SilentRegression.Providers.RequestArtifact

  @keys ~w(
    provider
    requested_model
    request_mode
    request_schema_version
    request_template
    system_prompt
    user_prompt_template
    response_format
    generation_config
  )

  def normalize(attributes) when is_map(attributes) do
    with {:ok, cases, attributes} <- extract_cases(attributes),
         {:ok, attributes} <- JsonValue.normalize(attributes),
         [] <- Map.keys(attributes) -- @keys,
         {:ok, {provider, requested_model}} <- provider_model(attributes),
         {:ok, request_mode} <- request_mode(attributes),
         {:ok, request_schema_version} <- request_schema_version(attributes),
         {:ok, request_template} <-
           RequestArtifact.normalize_template(
             provider,
             request_mode,
             Map.get(attributes, "request_template", %{})
           ),
         {:ok, {system_prompt, user_prompt_template}} <-
           legacy_prompts(attributes, request_mode),
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
        request_mode: request_mode,
        request_schema_version: request_schema_version,
        request_template: request_template,
        system_prompt: system_prompt,
        user_prompt_template: user_prompt_template,
        response_format: response_format,
        generation_config: generation_config,
        cases: cases,
        case_set_fingerprint: Fingerprint.case_set_digest(cases)
      }

      with :ok <- validate_renderable_requests(normalized, cases) do
        {:ok, Map.put(normalized, :fingerprint, Fingerprint.monitor_version_digest(normalized))}
      end
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

  defp request_mode(attributes) do
    attributes
    |> Map.get("request_mode", "legacy_wrapped_v1")
    |> RequestArtifact.cast_mode()
    |> case do
      {:ok, mode} -> {:ok, mode}
      {:error, _reason} -> {:error, %{field: :request_mode, reason: :invalid}}
    end
  end

  defp request_schema_version(attributes) do
    supported_version = RequestArtifact.request_schema_version()
    version = Map.get(attributes, "request_schema_version", supported_version)

    if version == supported_version,
      do: {:ok, version},
      else: {:error, %{field: :request_schema_version, reason: :invalid}}
  end

  defp validate_renderable_requests(normalized, cases) do
    cases
    |> Enum.filter(&(&1.status == :active))
    |> Enum.reduce_while(:ok, fn case_definition, :ok ->
      case RequestArtifact.build(normalized, case_definition) do
        {:ok, _artifact} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, %{field: :request_template, reason: reason}}}
      end
    end)
  end

  defp legacy_prompts(attributes, :legacy_wrapped_v1) do
    with {:ok, system_prompt} <- prompt(attributes, "system_prompt", :system_prompt, false),
         {:ok, user_prompt_template} <-
           prompt(attributes, "user_prompt_template", :user_prompt_template, true) do
      {:ok, {system_prompt, user_prompt_template}}
    end
  end

  defp legacy_prompts(attributes, :provider_native_v1) do
    with {:ok, system_prompt} <- prompt(attributes, "system_prompt", :system_prompt, false),
         {:ok, user_prompt_template} <-
           prompt(attributes, "user_prompt_template", :user_prompt_template, false),
         true <- system_prompt == "" and user_prompt_template == "" do
      {:ok, {"", ""}}
    else
      false -> {:error, %{field: :request_template, reason: :legacy_prompt_not_allowed}}
      {:error, reason} -> {:error, reason}
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
