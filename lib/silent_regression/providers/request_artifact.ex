defmodule SilentRegression.Providers.RequestArtifact do
  @moduledoc """
  Strict, versioned construction of the exact secret-free provider request.

  Legacy monitor versions retain the original product wrapper. New monitor versions store a
  provider-native text-message template and never receive an implicit prompt section.
  """

  alias SilentRegression.Captures.Prompt
  alias SilentRegression.Monitors.{Fingerprint, JsonValue, Limits}

  @request_schema_version 1
  @modes [:legacy_wrapped_v1, :provider_native_v1]
  @openai_roles ~w(user assistant system developer)
  @anthropic_roles ~w(user assistant)

  @openai_endpoint "https://api.openai.com/v1/responses"
  @openai_api_version "v1"
  @anthropic_endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_api_version "2023-06-01"

  @type built :: %{
          artifact: map(),
          fingerprint: String.t(),
          mode: :legacy_wrapped_v1 | :provider_native_v1,
          schema_version: pos_integer()
        }

  def request_schema_version, do: @request_schema_version
  def modes, do: @modes

  def cast_mode(value) when value in @modes, do: {:ok, value}
  def cast_mode("legacy_wrapped_v1"), do: {:ok, :legacy_wrapped_v1}
  def cast_mode("provider_native_v1"), do: {:ok, :provider_native_v1}
  def cast_mode(_value), do: {:error, :invalid_request_mode}

  def normalize_template(_provider, :legacy_wrapped_v1, template) when template in [%{}, nil],
    do: {:ok, %{}}

  def normalize_template(:openai, :provider_native_v1, template) do
    with {:ok, template} <- normalize_json_object(template),
         [] <- Map.keys(template) -- ~w(input instructions),
         {:ok, instructions} <- optional_template_text(template, "instructions"),
         {:ok, input} <- messages(template["input"], @openai_roles, :openai),
         {:ok, normalized} <-
           bounded_template(put_optional(%{"input" => input}, "instructions", instructions)) do
      {:ok, normalized}
    else
      _reason -> {:error, :invalid_request_template}
    end
  end

  def normalize_template(:anthropic, :provider_native_v1, template) do
    with {:ok, template} <- normalize_json_object(template),
         [] <- Map.keys(template) -- ~w(messages system),
         {:ok, system} <- optional_template_text(template, "system"),
         {:ok, messages} <- messages(template["messages"], @anthropic_roles, :anthropic),
         :ok <- alternating_anthropic_messages(messages),
         {:ok, normalized} <-
           bounded_template(put_optional(%{"messages" => messages}, "system", system)) do
      {:ok, normalized}
    else
      _reason -> {:error, :invalid_request_template}
    end
  end

  def normalize_template(_provider, _mode, _template),
    do: {:error, :invalid_request_template}

  @spec build(map() | struct(), map() | struct()) :: {:ok, built()} | {:error, atom()}
  def build(configuration, case_definition) do
    with {:ok, provider} <- provider(field(configuration, :provider)),
         {:ok, mode} <- cast_mode(field(configuration, :request_mode)),
         @request_schema_version <- field(configuration, :request_schema_version),
         {:ok, template} <-
           normalize_template(provider, mode, field(configuration, :request_template) || %{}),
         {:ok, body} <- build_body(provider, mode, configuration, case_definition, template) do
      artifact = artifact(provider, mode, body)

      {:ok,
       %{
         artifact: artifact,
         fingerprint: Fingerprint.digest(artifact),
         mode: mode,
         schema_version: @request_schema_version
       }}
    else
      {:error, reason} -> {:error, reason}
      _reason -> {:error, :invalid_request_configuration}
    end
  end

  defp build_body(provider, :legacy_wrapped_v1, configuration, case_definition, %{}) do
    variables = case_field(case_definition, :input_variables, %{})

    with {:ok, user_prompt} <-
           Prompt.render(field(configuration, :user_prompt_template), variables),
         {:ok, response_format} <- response_format(configuration),
         {:ok, generation_config} <- generation_config(configuration) do
      user_input =
        """
        Context:
        #{legacy_context(case_field(case_definition, :frozen_context, ""))}

        Question:
        #{user_prompt}

        Response requirements:
        #{Jason.encode!(response_format)}
        """
        |> String.trim()

      legacy_body(
        provider,
        field(configuration, :requested_model),
        field(configuration, :system_prompt) || "",
        user_input,
        response_format,
        generation_config
      )
    end
  end

  defp build_body(provider, :provider_native_v1, configuration, case_definition, template) do
    variables =
      case_definition
      |> case_field(:input_variables, %{})
      |> Map.put("frozen_context", case_field(case_definition, :frozen_context, ""))

    with false <-
           Map.has_key?(case_field(case_definition, :input_variables, %{}), "frozen_context"),
         {:ok, rendered_template} <- render_template(template, variables),
         {:ok, response_format} <- response_format(configuration),
         {:ok, generation_config} <- generation_config(configuration) do
      native_body(
        provider,
        field(configuration, :requested_model),
        rendered_template,
        response_format,
        generation_config
      )
    else
      true -> {:error, :reserved_frozen_context_variable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_body(:openai, model, system_prompt, user_input, response_format, generation) do
    %{
      "model" => model,
      "store" => false,
      "input" => [
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => user_input}]}
      ]
    }
    |> Map.put("instructions", system_prompt)
    |> apply_openai_generation(generation)
    |> put_optional("text", openai_text(response_format))
    |> then(&{:ok, &1})
  end

  defp legacy_body(:anthropic, model, system_prompt, user_input, _response_format, generation) do
    %{
      "model" => model,
      "max_tokens" => generation["max_output_tokens"],
      "system" => system_prompt,
      "messages" => [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => user_input}]}
      ]
    }
    |> apply_anthropic_generation(generation)
    |> then(&{:ok, &1})
  end

  defp native_body(:openai, model, template, response_format, generation) do
    template
    |> Map.merge(%{"model" => model, "store" => false})
    |> apply_openai_generation(generation)
    |> put_optional("text", openai_text(response_format))
    |> then(&{:ok, &1})
  end

  defp native_body(:anthropic, model, template, response_format, generation) do
    with {:ok, output_config} <- anthropic_output_config(response_format) do
      template
      |> Map.merge(%{"model" => model, "max_tokens" => generation["max_output_tokens"]})
      |> apply_anthropic_generation(generation)
      |> put_optional("output_config", output_config)
      |> then(&{:ok, &1})
    end
  end

  defp artifact(:openai, mode, body) do
    %{
      "artifact_schema" => "provider-request-artifact-v1",
      "request_mode" => Atom.to_string(mode),
      "request_schema_version" => @request_schema_version,
      "provider" => "openai",
      "http_method" => "POST",
      "api_endpoint" => @openai_endpoint,
      "api_version" => @openai_api_version,
      "body" => body
    }
  end

  defp artifact(:anthropic, mode, body) do
    %{
      "artifact_schema" => "provider-request-artifact-v1",
      "request_mode" => Atom.to_string(mode),
      "request_schema_version" => @request_schema_version,
      "provider" => "anthropic",
      "http_method" => "POST",
      "api_endpoint" => @anthropic_endpoint,
      "api_version" => @anthropic_api_version,
      "body" => body
    }
  end

  defp render_template(template, variables) do
    template
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, rendered} when key in ["instructions", "system"] ->
        case Prompt.render(value, variables) do
          {:ok, text} -> {:cont, {:ok, Map.put(rendered, key, text)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {key, messages}, {:ok, rendered} when key in ["input", "messages"] ->
        case render_messages(messages, variables) do
          {:ok, messages} -> {:cont, {:ok, Map.put(rendered, key, messages)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp render_messages(messages, variables) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, rendered} ->
      case Prompt.render(message["content"], variables) do
        {:ok, content} when content != "" ->
          {:cont, {:ok, [%{"role" => message["role"], "content" => content} | rendered]}}

        {:ok, ""} ->
          {:halt, {:error, :empty_rendered_message}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp messages(values, allowed_roles, provider)
       when is_list(values) and values != [] do
    if length(values) <= Limits.fetch!(:max_request_messages) do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
        case message(value, allowed_roles) do
          {:ok, message} -> {:cont, {:ok, [message | normalized]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, normalized} ->
          normalized = Enum.reverse(normalized)

          if provider == :openai and Enum.any?(normalized, &(&1["role"] == "user")) do
            {:ok, normalized}
          else
            if provider == :anthropic,
              do: {:ok, normalized},
              else: {:error, :user_message_required}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :too_many_messages}
    end
  end

  defp messages(_values, _allowed_roles, _provider), do: {:error, :messages_required}

  defp message(value, allowed_roles) when is_map(value) do
    with {:ok, value} <- normalize_json_object(value),
         [] <- Map.keys(value) -- ~w(content role),
         role when is_binary(role) <- value["role"],
         true <- role in allowed_roles,
         {:ok, content} <- required_template_text(value["content"]) do
      {:ok, %{"role" => role, "content" => content}}
    else
      _reason -> {:error, :invalid_message}
    end
  end

  defp message(_value, _allowed_roles), do: {:error, :invalid_message}

  defp alternating_anthropic_messages([%{"role" => "user"} | _rest] = messages) do
    last_role = messages |> List.last() |> Map.fetch!("role")

    if last_role == "user" and alternating_roles?(messages),
      do: :ok,
      else: {:error, :invalid_anthropic_message_order}
  end

  defp alternating_anthropic_messages(_messages),
    do: {:error, :invalid_anthropic_message_order}

  defp alternating_roles?(messages) do
    messages
    |> Enum.map(& &1["role"])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left != right end)
  end

  defp optional_template_text(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, value} -> required_template_text(value)
    end
  end

  defp required_template_text(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= Limits.fetch!(:max_prompt_bytes),
      do: {:ok, value},
      else: {:error, :invalid_template_text}
  end

  defp required_template_text(_value), do: {:error, :invalid_template_text}

  defp bounded_template(template) do
    with {:ok, size} <- JsonValue.encoded_size(template),
         true <- size <= Limits.fetch!(:max_request_template_bytes) do
      {:ok, template}
    else
      _reason -> {:error, :request_template_too_large}
    end
  end

  defp normalize_json_object(value) when is_map(value), do: JsonValue.normalize(value)
  defp normalize_json_object(_value), do: {:error, :invalid_json_value}

  defp response_format(configuration) do
    case field(configuration, :response_format) do
      value when is_map(value) -> {:ok, value}
      _value -> {:error, :invalid_response_format}
    end
  end

  defp generation_config(configuration) do
    case field(configuration, :generation_config) do
      value when is_map(value) -> {:ok, value}
      _value -> {:error, :invalid_generation_config}
    end
  end

  defp apply_openai_generation(body, generation) do
    body
    |> put_optional("max_output_tokens", generation["max_output_tokens"])
    |> put_optional("temperature", generation["temperature"])
    |> put_optional("top_p", generation["top_p"])
    |> put_optional("reasoning", reasoning(generation["reasoning_effort"]))
  end

  defp apply_anthropic_generation(body, generation) do
    body
    |> put_optional("temperature", generation["temperature"])
    |> put_optional("top_p", generation["top_p"])
  end

  defp reasoning(nil), do: nil
  defp reasoning(effort), do: %{"effort" => effort}

  defp openai_text(%{"type" => "text"}), do: nil
  defp openai_text(%{"type" => "json_object"}), do: %{"format" => %{"type" => "json_object"}}

  defp openai_text(%{"type" => "json_schema"} = format) do
    %{
      "format" => %{
        "type" => "json_schema",
        "name" => format["name"],
        "schema" => format["schema"],
        "strict" => Map.get(format, "strict", true)
      }
    }
  end

  defp anthropic_output_config(%{"type" => "text"}), do: {:ok, nil}

  defp anthropic_output_config(%{"type" => "json_schema", "schema" => schema}) do
    {:ok, %{"format" => %{"type" => "json_schema", "schema" => schema}}}
  end

  defp anthropic_output_config(_format), do: {:error, :unsupported_response_format}

  defp legacy_context(""), do: "No frozen context was supplied."
  defp legacy_context(value), do: value

  defp provider(value) when value in [:openai, :anthropic], do: {:ok, value}
  defp provider("openai"), do: {:ok, :openai}
  defp provider("anthropic"), do: {:ok, :anthropic}
  defp provider(_value), do: {:error, :unsupported_provider}

  defp field(value, key) when is_struct(value), do: Map.get(value, key)

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp case_field(value, key, default) when is_struct(value), do: Map.get(value, key, default)

  defp case_field(value, key, default) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key), default))

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
