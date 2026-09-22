defmodule SilentRegression.GuidedSetups.Routing do
  @moduledoc "Routing recipe v1: raw authoring is separate from executable validation."
  alias SilentRegression.{CaseExpectations, Contracts}
  alias SilentRegression.Captures.Prompt
  alias SilentRegression.Contracts.{Observation, Text}

  alias SilentRegression.Monitors.{
    Fingerprint,
    GenerationConfig,
    JsonValue,
    ModelCatalog,
    VersionInput
  }

  alias SilentRegression.Providers.RequestArtifact

  @fields ~w(name description provider model credentialId mode instruction messages nativeJson generationJson labelsText cases)
  @strings ~w(name description provider model credentialId mode instruction nativeJson generationJson labelsText)

  def empty do
    %{
      "name" => "",
      "description" => "",
      "provider" => "openai",
      "model" => "",
      "credentialId" => "",
      "mode" => "messages",
      "instruction" => "",
      "messages" => [%{"role" => "user", "content" => ""}],
      "nativeJson" => "",
      "generationJson" => ~s({"max_output_tokens":512}),
      "labelsText" => "",
      "cases" => []
    }
  end

  # No trimming or JSON decoding here: even an unfinished native request survives reload.
  def validate_raw(raw) when is_map(raw) do
    with true <- Enum.sort(Map.keys(raw)) == Enum.sort(@fields),
         true <- Enum.all?(@strings, &text?(raw[&1], 65_536)),
         true <- raw["provider"] in ~w(openai anthropic),
         true <- raw["mode"] in ~w(messages native),
         true <- list?(raw["messages"], 20, &message?/1),
         true <- list?(raw["cases"], 20, &case?/1),
         {:ok, bytes} <- JsonValue.encoded_size(raw),
         true <- bytes <= 240_000 do
      :ok
    else
      _ -> {:error, :invalid_draft}
    end
  end

  def validate_raw(_), do: {:error, :invalid_draft}

  def configuration(raw) do
    with :ok <- metadata(raw),
         {:ok, {provider, model}} <- selected_model(raw),
         {:ok, template} <- validated_template(raw),
         {:ok, generation} <- generation(raw, provider, model) do
      {:ok,
       %{
         provider: Atom.to_string(provider),
         requested_model: model,
         request_mode: "provider_native_v1",
         request_schema_version: 1,
         request_template: template,
         response_format: %{"type" => "text"},
         generation_config: generation,
         system_prompt: "",
         user_prompt_template: ""
       }}
    else
      error -> error
    end
  end

  defp metadata(raw) do
    cond do
      String.trim(raw["name"]) == "" ->
        request_error(
          "Give this monitor a name before continuing. You can still save an unfinished draft."
        )

      String.length(raw["name"]) > 120 ->
        request_error("Keep the monitor name within 120 characters.")

      String.length(raw["description"]) > 2_000 ->
        request_error("Keep the description within 2,000 characters.")

      true ->
        :ok
    end
  end

  defp selected_model(raw) do
    case ModelCatalog.validate(raw["provider"], raw["model"]) do
      {:ok, pair} -> {:ok, pair}
      _ -> request_error("Choose an available model for the selected provider.")
    end
  end

  defp validated_template(raw) do
    case {raw["mode"], template(raw)} do
      {_, {:ok, template}} ->
        {:ok, template}

      {"native", _} ->
        request_error(
          "Complete a valid native template: input/instructions for OpenAI, or messages/system for Anthropic. Keep model and generation settings in their separate fields."
        )

      _ ->
        request_error(
          "Add non-empty ordered messages (maximum 20). Anthropic messages must alternate user/assistant and start with user. Check each role and the 40 KB text limit."
        )
    end
  end

  defp generation(raw, provider, model) do
    with {:ok, json} <- Jason.decode(raw["generationJson"]),
         {:ok, generation} <- GenerationConfig.normalize(json),
         :ok <- ModelCatalog.validate_generation_config(provider, model, generation) do
      {:ok, generation}
    else
      _ ->
        request_error(
          "Open Generation settings and complete valid JSON with max_output_tokens. Only parameters supported by this exact model are accepted."
        )
    end
  end

  defp request_error(message), do: {:error, {:request, message}}

  def variables(raw) do
    case template(raw) do
      {:ok, template} ->
        template
        |> Map.values()
        |> Enum.flat_map(fn
          value when is_binary(value) ->
            Prompt.variable_names(value)

          messages when is_list(messages) ->
            Enum.flat_map(messages, &Prompt.variable_names(&1["content"]))
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  def compile(raw) do
    with {:ok, config} <- configuration(raw),
         {:ok, labels} <- labels(raw),
         {:ok, cases} <- cases(raw, labels),
         attrs <- Map.put(config, :cases, cases),
         {:ok, version} <- normalize_version(attrs) do
      root = %{
        "id" => "contract",
        "type" => "all",
        "rules" => [
          %{"id" => "allowed_label", "type" => "classification", "allowed_values" => labels}
        ]
      }

      {:ok, contract} =
        Contracts.parse_contract(%{
          "schema_version" => 1,
          "contract_id" => "routing-preview",
          "contract_version" => 1,
          "monitor_id" => "routing-draft",
          "root" => root
        })

      identity =
        Fingerprint.digest(%{
          "recipe" => "routing",
          "version" => 1,
          "configuration" => version.fingerprint,
          "evaluator_engine" => Contracts.evaluator_engine_version(),
          "checks" => contract.fingerprint
        })

      proof = proof(version, contract, labels, identity)

      requests =
        Enum.map(version.cases, fn input ->
          {:ok, request} = RequestArtifact.build(version, input)

          %{
            case_key: input.case_key,
            name: input.name,
            artifact_json: Jason.encode!(request.artifact, pretty: true),
            fingerprint: request.fingerprint
          }
        end)

      {:ok,
       %{
         attributes: attrs,
         version: version,
         root: root,
         identity: identity,
         proof: proof,
         requests: requests
       }}
    end
  end

  defp normalize_version(attrs) do
    case VersionInput.normalize(attrs) do
      {:ok, version} ->
        {:ok, version}

      _ ->
        {:error,
         {:examples,
          "Each example needs a unique name/key and values for every request variable. Check the rendered request and the request/case size limits."}}
    end
  end

  defp labels(raw) do
    labels = raw["labelsText"] |> String.split("\n") |> Enum.map(&String.trim/1)
    normalized = Enum.map(labels, &Text.normalize/1)

    if length(labels) in 2..8 and Enum.all?(labels, &(byte_size(&1) in 1..120)) and
         Enum.all?(normalized, &(&1 != "")) and
         Enum.uniq(normalized) == normalized do
      {:ok, labels}
    else
      {:error,
       {:examples,
        "Enter 2–8 distinct labels, one per line, without blank lines. Labels use Unicode normalization, case folding and punctuation/whitespace normalization, not semantic interpretation."}}
    end
  end

  defp cases(raw, labels) do
    if raw["cases"] != [] and Enum.all?(raw["cases"], &(&1["expected"] in labels)) do
      {:ok,
       Enum.with_index(raw["cases"], fn row, index ->
         %{
           case_key: row["key"],
           name: row["name"],
           position: index,
           status: "active",
           input_variables: row["variables"],
           frozen_context: row["context"],
           expectation_schema_version: CaseExpectations.schema_version(),
           expectation: %{
             "checks" => [
               %{
                 "id" => "expected_label",
                 "type" => "label",
                 "allowed_values" => [row["expected"]]
               }
             ]
           }
         }
       end)}
    else
      {:error,
       {:examples,
        "Add 1–20 representative inputs and explicitly select the correct label for each. No answer is inferred from the model."}}
    end
  end

  defp template(%{"mode" => "native"} = raw) do
    with {:ok, native} <- Jason.decode(raw["nativeJson"]) do
      RequestArtifact.normalize_template(provider(raw), :provider_native_v1, native)
    end
  end

  defp template(raw) do
    {messages, instruction} =
      if raw["provider"] == "openai", do: {"input", "instructions"}, else: {"messages", "system"}

    template = %{messages => raw["messages"]}

    template =
      if raw["instruction"] == "",
        do: template,
        else: Map.put(template, instruction, raw["instruction"])

    RequestArtifact.normalize_template(provider(raw), :provider_native_v1, template)
  end

  defp provider(%{"provider" => "openai"}), do: :openai
  defp provider(_), do: :anthropic

  defp proof(version, contract, labels, identity) do
    # Candidates are synthetic. Nothing below is a human judgment or provider observation.
    invalid = Enum.join(labels, " / ") <> " (not a label)"

    Enum.flat_map(version.cases, fn input ->
      expected = hd(input.expectation["checks"])["allowed_values"] |> hd()
      wrong = Enum.find(labels, &(&1 != expected))

      Enum.map(
        [{expected, "pass", "pass"}, {wrong, "pass", "fail"}, {invalid, "fail", "fail"}],
        fn {output, proposed_shared, proposed_case} ->
          {:ok, shared} =
            Contracts.evaluate(contract, %Observation{id: "draft-proof", output_text: output})

          specific =
            CaseExpectations.evaluate(
              input.expectation_schema_version,
              input.expectation,
              input.expectation_fingerprint,
              output
            )

          fingerprint =
            Fingerprint.digest(%{
              "identity" => identity,
              "case" => input.fingerprint,
              "output" => output
            })

          %{
            id: fingerprint,
            fingerprint: fingerprint,
            case_fingerprint: input.fingerprint,
            expectation_fingerprint: input.expectation_fingerprint,
            case_key: input.case_key,
            name: input.name,
            input_json: Jason.encode!(input.input_variables, pretty: true),
            context: input.frozen_context,
            expected: expected,
            output: output,
            proposed_shared: proposed_shared,
            proposed_case: proposed_case,
            shared: Atom.to_string(shared.status),
            specific: Atom.to_string(specific.status),
            reason: Enum.map_join(specific.results, " ", & &1.explanation)
          }
        end
      )
    end)
  end

  defp message?(row) when is_map(row),
    do:
      Enum.sort(Map.keys(row)) == ~w(content role) and text?(row["role"], 20) and
        text?(row["content"], 65_536)

  defp message?(_), do: false

  defp case?(row) when is_map(row) do
    Enum.sort(Map.keys(row)) == ~w(context expected key name variables) and
      Enum.all?(~w(context expected key name), &text?(row[&1], 65_536)) and
      is_map(row["variables"]) and map_size(row["variables"]) <= 50 and
      Enum.all?(row["variables"], fn {key, value} -> text?(key, 100) and text?(value, 65_536) end)
  end

  defp case?(_), do: false

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= max

  defp list?(value, max, validator),
    do: is_list(value) and length(value) <= max and Enum.all?(value, validator)
end
