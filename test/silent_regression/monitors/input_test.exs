defmodule SilentRegression.Monitors.InputTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Monitors.{CaseImport, CaseInput, VersionInput}
  alias SilentRegression.MonitorsFixtures

  describe "version input" do
    test "normalizes manual and versioned JSON-imported cases identically" do
      manual_case = %{
        case_key: "supported-answer",
        name: " Supported answer ",
        status: "active",
        input_variables: %{question: "Which plan includes SSO?"},
        frozen_context: "The Enterprise plan includes SSO."
      }

      import =
        Jason.encode!(%{
          schema_version: 1,
          cases: [manual_case]
        })

      assert {:ok, imported_cases} = CaseImport.parse(import)
      assert {:ok, manual_cases} = CaseInput.normalize_many([manual_case])
      assert imported_cases == manual_cases
    end

    test "rejects unknown import fields, schema versions, and invalid JSON" do
      assert {:error, %{reason: :invalid_schema}} =
               CaseImport.parse(~s({"schema_version":1,"cases":[],"other":true}))

      assert {:error, %{reason: :invalid_schema}} =
               CaseImport.parse(~s({"schema_version":2,"cases":[]}))

      assert {:error, %{reason: :invalid_json}} = CaseImport.parse("{")

      assert {:error, %{reason: :invalid_schema}} = CaseImport.parse("[]")
    end

    test "rejects malformed scalar case fields without raising" do
      assert {:error, %{field: :case}} =
               CaseInput.normalize(%{case_key: 123, name: 456}, 0)
    end

    test "uses exact allowlisted provider/model pairs without substitution" do
      attributes = MonitorsFixtures.valid_version_attributes()

      assert {:ok, normalized} = VersionInput.normalize(attributes)
      assert normalized.provider == :openai
      assert normalized.requested_model == "gpt-5.6-luna"

      assert {:error, %{field: :requested_model, reason: :model_not_allowed}} =
               VersionInput.normalize(%{attributes | requested_model: "gpt-5.6"})

      assert {:error, %{field: :requested_model, reason: :model_not_allowed}} =
               VersionInput.normalize(%{
                 attributes
                 | provider: "anthropic",
                   requested_model: "gpt-5.6-luna"
               })
    end

    test "enforces generation capabilities for the exact provider and model" do
      attributes = MonitorsFixtures.valid_version_attributes()

      assert {:error,
              %{
                field: :generation_config,
                reason: :unsupported_parameters,
                parameters: ["temperature"]
              }} =
               VersionInput.normalize(%{
                 attributes
                 | generation_config: %{max_output_tokens: 256, temperature: 0}
               })

      assert {:error,
              %{
                field: :generation_config,
                reason: :unsupported_reasoning_effort,
                reasoning_effort: "minimal"
              }} =
               VersionInput.normalize(%{
                 attributes
                 | generation_config: %{
                     max_output_tokens: 256,
                     reasoning_effort: "minimal"
                   }
               })

      assert {:ok, normalized} =
               VersionInput.normalize(%{
                 attributes
                 | generation_config: %{max_output_tokens: 256, reasoning_effort: "low"}
               })

      assert normalized.generation_config == %{
               "max_output_tokens" => 256,
               "reasoning_effort" => "low"
             }

      assert {:ok, anthropic} =
               VersionInput.normalize(%{
                 attributes
                 | provider: "anthropic",
                   requested_model: "claude-haiku-4-5-20251001",
                   generation_config: %{
                     max_output_tokens: 256,
                     temperature: 0.2,
                     top_p: 0.9
                   }
               })

      assert anthropic.generation_config == %{
               "max_output_tokens" => 256,
               "temperature" => 0.2,
               "top_p" => 0.9
             }
    end

    test "enforces active-case and payload limits" do
      attributes = MonitorsFixtures.valid_version_attributes()

      too_many =
        for index <- 1..21 do
          %{
            case_key: "case-#{index}",
            name: "Case #{index}",
            status: "active",
            input_variables: %{},
            frozen_context: ""
          }
        end

      assert {:error, %{field: :cases, reason: :invalid_active_case_count}} =
               VersionInput.normalize(%{attributes | cases: too_many})

      oversized_context = String.duplicate("x", 100_001)
      [case_attributes] = attributes.cases

      assert {:error, %{field: :case}} =
               VersionInput.normalize(%{
                 attributes
                 | cases: [%{case_attributes | frozen_context: oversized_context}]
               })

      assert {:error, %{field: :configuration}} =
               VersionInput.normalize(Map.put(attributes, :unknown, true))
    end

    test "normalizes provider-native request templates and validates every active case" do
      attributes =
        MonitorsFixtures.valid_version_attributes()
        |> Map.merge(%{
          request_mode: "provider_native_v1",
          request_schema_version: 1,
          request_template: %{
            input: [%{role: "user", content: "{{question}} / {{frozen_context}}"}]
          },
          system_prompt: "",
          user_prompt_template: ""
        })

      assert {:ok, normalized} = VersionInput.normalize(attributes)
      assert normalized.request_mode == :provider_native_v1

      assert normalized.request_template == %{
               "input" => [
                 %{"role" => "user", "content" => "{{question}} / {{frozen_context}}"}
               ]
             }

      assert {:error, %{field: :request_template, reason: {:missing_prompt_variable, "missing"}}} =
               VersionInput.normalize(%{
                 attributes
                 | request_template: %{
                     input: [%{role: "user", content: "{{missing}}"}]
                   }
               })

      assert {:error, %{field: :request_template, reason: :legacy_prompt_not_allowed}} =
               VersionInput.normalize(%{attributes | system_prompt: "Hidden instruction"})
    end
  end

  describe "fingerprints" do
    test "remain stable for metadata-only case edits and map key ordering" do
      base = MonitorsFixtures.valid_version_attributes()
      [case_attributes] = base.cases

      metadata_edit =
        %{base | cases: [%{case_attributes | name: "Renamed", position: 12}]}

      string_keyed = Jason.decode!(Jason.encode!(base))

      assert {:ok, normalized_base} = VersionInput.normalize(base)
      assert {:ok, normalized_metadata} = VersionInput.normalize(metadata_edit)
      assert {:ok, normalized_string_keyed} = VersionInput.normalize(string_keyed)

      assert normalized_base.fingerprint == normalized_metadata.fingerprint
      assert normalized_base.case_set_fingerprint == normalized_metadata.case_set_fingerprint
      assert normalized_base.fingerprint == normalized_string_keyed.fingerprint
    end

    test "change for every class of behavior-affecting edit" do
      base = MonitorsFixtures.valid_version_attributes()
      [case_attributes] = base.cases
      {:ok, normalized_base} = VersionInput.normalize(base)

      edits = [
        %{base | requested_model: "gpt-5.6-sol"},
        %{base | system_prompt: "A changed system prompt"},
        %{base | user_prompt_template: "Changed: {{question}}"},
        %{base | response_format: %{type: "text"}},
        %{base | generation_config: %{max_output_tokens: 512}},
        %{base | cases: [%{case_attributes | status: "disabled"}, active_case("fallback")]},
        %{base | cases: [%{case_attributes | input_variables: %{question: "Changed"}}]},
        %{base | cases: [%{case_attributes | frozen_context: "Changed context"}]},
        %{
          base
          | provider: "anthropic",
            requested_model: "claude-haiku-4-5-20251001"
        }
      ]

      fingerprints =
        Enum.map(edits, fn edit ->
          assert {:ok, normalized} = VersionInput.normalize(edit)
          normalized.fingerprint
        end)

      assert Enum.all?(fingerprints, &(&1 != normalized_base.fingerprint))
    end

    test "provider-native fingerprints change with effective templates but ignore legacy fields" do
      base =
        MonitorsFixtures.valid_version_attributes()
        |> Map.merge(%{
          request_mode: "provider_native_v1",
          request_schema_version: 1,
          request_template: %{
            input: [%{role: "user", content: "{{question}}"}]
          },
          system_prompt: "",
          user_prompt_template: ""
        })

      assert {:ok, normalized} = VersionInput.normalize(base)

      assert {:ok, changed} =
               VersionInput.normalize(%{
                 base
                 | request_template: %{
                     input: [%{role: "user", content: "Question: {{question}}"}]
                   }
               })

      refute normalized.fingerprint == changed.fingerprint
    end
  end

  defp active_case(case_key) do
    %{
      case_key: case_key,
      name: "Fallback",
      position: 1,
      status: "active",
      input_variables: %{question: "Fallback question"},
      frozen_context: ""
    }
  end
end
