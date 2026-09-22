defmodule SilentRegression.GuidedSetups.Proof do
  @moduledoc "Production-evaluated synthetic proposals with bounded, complete shared-rule coverage."
  alias SilentRegression.{CaseExpectations, Contracts}
  alias SilentRegression.Contracts.Observation
  alias SilentRegression.GuidedSetups.Recipes
  alias SilentRegression.Monitors.{Fingerprint, VersionInput}
  alias SilentRegression.Providers.RequestArtifact

  def compile(recipe, config, rules, cases, candidates) do
    attrs = Map.put(config, :cases, cases)
    root = %{"id" => "contract", "type" => "all", "rules" => rules}

    with {:ok, version} <- VersionInput.normalize(attrs),
         {:ok, contract} <-
           Contracts.parse_contract(%{
             "schema_version" => 1,
             "contract_id" => "#{recipe}-preview",
             "contract_version" => 1,
             "monitor_id" => "guided-draft",
             "root" => root
           }) do
      identity =
        Fingerprint.digest(%{
          "recipe" => recipe,
          "version" => 1,
          "configuration" => version.fingerprint,
          "evaluator_engine" => Contracts.evaluator_engine_version(),
          "checks" => contract.fingerprint
        })

      proof =
        candidates
        |> Enum.uniq_by(fn {index, output, _} -> {index, output} end)
        |> Enum.map(&evaluate(&1, version, contract, identity))

      with :ok <- validate(proof, version.cases, rules) do
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
    else
      _ ->
        Recipes.error(
          "Check unique example names/keys, request variable values and the configured field, literal or source limits. No unsupported rule is silently ignored."
        )
    end
  end

  # Only explicitly reviewed rows reach this selector. Keep one per distinct shared-rule result,
  # not one per case: case-linked evidence remains in the sealed draft's complete review record.
  def shared_fixtures(proof), do: Enum.uniq_by(proof, &Enum.sort(&1.failed_rule_ids))

  defp evaluate({index, output, purpose}, version, contract, identity) do
    input = Enum.at(version.cases, index)

    {:ok, shared} =
      Contracts.evaluate(contract, %Observation{id: "guided-proof", output_text: output})

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

    failed_ids =
      shared.rule_results
      |> Enum.filter(&(&1.rule_id != "contract" and &1.status == :fail))
      |> Enum.map(& &1.rule_id)
      |> Enum.sort()

    %{
      id: fingerprint,
      fingerprint: fingerprint,
      case_fingerprint: input.fingerprint,
      expectation_fingerprint: input.expectation_fingerprint,
      case_key: input.case_key,
      name: input.name,
      input_json: Jason.encode!(input.input_variables, pretty: true),
      context: input.frozen_context,
      expected: Recipes.summary(input.expectation),
      output: output,
      purpose: purpose,
      proposed_shared: Atom.to_string(shared.status),
      proposed_case: Atom.to_string(specific.status),
      shared: Atom.to_string(shared.status),
      specific: Atom.to_string(specific.status),
      failed_rule_ids: failed_ids,
      reason:
        purpose <>
          " " <> Enum.map_join(shared.rule_results ++ specific.results, " ", & &1.explanation)
    }
  end

  defp validate(proof, cases, rules) do
    cond do
      length(proof) > 60 or Enum.sum(Enum.map(proof, &(byte_size(&1.output) + 900))) > 85_000 ->
        Recipes.error(
          "Local proof is too large. Shorten literal values/source IDs or use fewer examples; review is limited to 60 proposals and 85 KB of estimated evidence."
        )

      Enum.any?(proof, &(&1.shared not in ~w(pass fail) or &1.specific not in ~w(pass fail))) ->
        Recipes.error("A proposal could not be evaluated safely. Check the configured limits.")

      Enum.any?(cases, fn input ->
        rows = Enum.filter(proof, &(&1.case_key == input.case_key))

        not Enum.any?(rows, &(&1.shared == "pass" and &1.specific == "pass")) or
            not Enum.any?(rows, &(&1.specific == "fail"))
      end) ->
        Recipes.error(
          "Shared rules and a case expectation conflict, or a counterexample cannot distinguish them. Check required/prohibited overlaps, source subsets, attribution punctuation/distance, and numeric values before reviewing proof."
        )

      length(shared_fixtures(proof)) > 20 or
          Enum.any?(rules, fn rule ->
            not Enum.any?(proof, &(rule["id"] in &1.failed_rule_ids)) or
                not Enum.any?(proof, &(rule["id"] not in &1.failed_rule_ids))
          end) ->
        Recipes.error(
          "These settings cannot produce complete bounded positive/negative proof for every shared rule. Adjust the declarations or use advanced authoring; no coverage is waived automatically."
        )

      true ->
        :ok
    end
  end
end
