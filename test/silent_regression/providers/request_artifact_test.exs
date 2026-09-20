defmodule SilentRegression.Providers.RequestArtifactTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Providers.RequestArtifact

  describe "provider_native_v1" do
    test "builds an exact OpenAI Responses body without an implicit wrapper" do
      configuration = %{
        provider: :openai,
        requested_model: "gpt-5.6-luna",
        request_mode: :provider_native_v1,
        request_schema_version: 1,
        request_template: %{
          "instructions" => "Use only the supplied policy.",
          "input" => [
            %{"role" => "developer", "content" => "Return a short answer."},
            %{
              "role" => "user",
              "content" => "Policy: {{frozen_context}}\nQuestion: {{question}}"
            }
          ]
        },
        response_format: %{"type" => "json_object"},
        generation_config: %{"max_output_tokens" => 256, "reasoning_effort" => "low"}
      }

      assert {:ok, built} = RequestArtifact.build(configuration, case_definition())

      assert built.mode == :provider_native_v1
      assert built.schema_version == 1
      assert byte_size(built.fingerprint) == 64

      assert built.artifact == %{
               "artifact_schema" => "provider-request-artifact-v1",
               "request_mode" => "provider_native_v1",
               "request_schema_version" => 1,
               "provider" => "openai",
               "http_method" => "POST",
               "api_endpoint" => "https://api.openai.com/v1/responses",
               "api_version" => "v1",
               "body" => %{
                 "model" => "gpt-5.6-luna",
                 "store" => false,
                 "instructions" => "Use only the supplied policy.",
                 "input" => [
                   %{"role" => "developer", "content" => "Return a short answer."},
                   %{
                     "role" => "user",
                     "content" =>
                       "Policy: Enterprise includes SSO.\nQuestion: Which plan includes SSO?"
                   }
                 ],
                 "max_output_tokens" => 256,
                 "reasoning" => %{"effort" => "low"},
                 "text" => %{"format" => %{"type" => "json_object"}}
               }
             }

      encoded = Jason.encode!(built.artifact)
      refute encoded =~ "Context:"
      refute encoded =~ "Response requirements:"
      refute encoded =~ "No frozen context was supplied."
    end

    test "builds Anthropic Messages JSON schema output and omits unused context" do
      configuration = %{
        provider: :anthropic,
        requested_model: "claude-haiku-4-5-20251001",
        request_mode: :provider_native_v1,
        request_schema_version: 1,
        request_template: %{
          "system" => "Classify the request.",
          "messages" => [
            %{"role" => "user", "content" => "Question: {{question}}"}
          ]
        },
        response_format: %{
          "type" => "json_schema",
          "name" => "classification",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "properties" => %{"label" => %{"type" => "string"}},
            "required" => ["label"],
            "additionalProperties" => false
          }
        },
        generation_config: %{"max_output_tokens" => 128}
      }

      assert {:ok, built} = RequestArtifact.build(configuration, case_definition())

      assert built.artifact["body"] == %{
               "model" => "claude-haiku-4-5-20251001",
               "max_tokens" => 128,
               "system" => "Classify the request.",
               "messages" => [
                 %{"role" => "user", "content" => "Question: Which plan includes SSO?"}
               ],
               "output_config" => %{
                 "format" => %{
                   "type" => "json_schema",
                   "schema" => configuration.response_format["schema"]
                 }
               }
             }

      refute Jason.encode!(built.artifact) =~ "Enterprise includes SSO."
    end

    test "rejects unknown fields, invalid Anthropic order, and reserved variable collisions" do
      assert {:error, :invalid_request_template} =
               RequestArtifact.normalize_template(:openai, :provider_native_v1, %{
                 "input" => [%{"role" => "user", "content" => "Hello"}],
                 "tools" => []
               })

      assert {:error, :invalid_request_template} =
               RequestArtifact.normalize_template(:anthropic, :provider_native_v1, %{
                 "messages" => [%{"role" => "assistant", "content" => "Hello"}]
               })

      configuration = native_configuration()

      assert {:error, :reserved_frozen_context_variable} =
               RequestArtifact.build(configuration, %{
                 case_definition()
                 | input_variables: %{
                     "question" => "Question",
                     "frozen_context" => "shadowed"
                   }
               })
    end

    test "rejects Anthropic unconstrained JSON object mode" do
      configuration = %{
        native_configuration()
        | provider: :anthropic,
          requested_model: "claude-haiku-4-5-20251001",
          request_template: %{
            "messages" => [%{"role" => "user", "content" => "{{question}}"}]
          }
      }

      assert {:error, :unsupported_response_format} =
               RequestArtifact.build(configuration, case_definition())
    end
  end

  test "legacy_wrapped_v1 preserves the original empty-context wrapper" do
    configuration = %{
      provider: :openai,
      requested_model: "gpt-5.6-luna",
      request_mode: :legacy_wrapped_v1,
      request_schema_version: 1,
      request_template: %{},
      system_prompt: "Answer only from context.",
      user_prompt_template: "{{question}}",
      response_format: %{"type" => "text"},
      generation_config: %{"max_output_tokens" => 64}
    }

    assert {:ok, built} =
             RequestArtifact.build(configuration, %{case_definition() | frozen_context: ""})

    [message] = built.artifact["body"]["input"]
    [content] = message["content"]

    assert content["text"] ==
             "Context:\nNo frozen context was supplied.\n\nQuestion:\nWhich plan includes SSO?\n\nResponse requirements:\n{\"type\":\"text\"}"
  end

  defp native_configuration do
    %{
      provider: :openai,
      requested_model: "gpt-5.6-luna",
      request_mode: :provider_native_v1,
      request_schema_version: 1,
      request_template: %{
        "input" => [%{"role" => "user", "content" => "{{question}}"}]
      },
      system_prompt: "",
      user_prompt_template: "",
      response_format: %{"type" => "json_object"},
      generation_config: %{"max_output_tokens" => 64}
    }
  end

  defp case_definition do
    %{
      case_id: "supported-answer",
      input_variables: %{"question" => "Which plan includes SSO?"},
      frozen_context: "Enterprise includes SSO."
    }
  end
end
