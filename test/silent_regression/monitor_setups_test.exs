defmodule SilentRegression.MonitorSetupsTest do
  use SilentRegression.DataCase, async: true

  import Ecto.Query
  import SilentRegression.ContractAuthoringFixtures

  alias SilentRegression.{
    Baselines,
    Captures,
    MonitorOperations,
    MonitorSetups,
    Monitors,
    ProductAnalytics,
    ProviderCredentials,
    Repo,
    Reviews
  }

  alias SilentRegression.ContractAuthoring.ContractVersion
  alias SilentRegression.MonitorSetups.Setup
  alias SilentRegression.Monitors.{CaseVersion, Monitor, MonitorVersion}

  alias SilentRegression.{
    MonitorSetupsFixtures,
    ProviderCredentialsFixtures,
    WorkspacesFixtures
  }

  setup do
    scope = WorkspacesFixtures.workspace_scope_fixture()
    other_scope = WorkspacesFixtures.workspace_scope_fixture()
    %{scope: scope, other_scope: other_scope}
  end

  describe "start and resume" do
    test "persists a monitor and separate setup with derived purpose progress", %{scope: scope} do
      %{monitor: monitor, setup: setup} = MonitorSetupsFixtures.setup_fixture(scope)

      assert setup.monitor_id == monitor.id
      assert setup.workspace_id == scope.workspace.id
      assert setup.status == :in_progress

      assert %{
               completed: %{
                 purpose: true,
                 connection: false,
                 prompt: false,
                 cases: false
               },
               completed_count: 1,
               next_step: :connection,
               percent: 25,
               ready?: false
             } = MonitorSetups.progress(scope, setup)

      assert {:ok, resumed} = MonitorSetups.get(scope, monitor.id)
      assert resumed.id == setup.id

      events = ProductAnalytics.list_events(scope)

      assert Enum.map(events, & &1.name) == [
               "monitor_setup.started",
               "monitor_setup.step_completed"
             ]

      refute inspect(events) =~ monitor.description
    end

    test "updates purpose and records explicit save-and-exit without content", %{scope: scope} do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)

      assert {:ok, setup} =
               MonitorSetups.update_purpose(scope, monitor.id, %{
                 name: "Renamed workflow",
                 description: "Sensitive customer purpose"
               })

      assert setup.monitor.name == "Renamed workflow"
      assert {:ok, _setup} = MonitorSetups.leave(scope, monitor.id, :purpose)

      [left] =
        scope
        |> ProductAnalytics.list_events()
        |> Enum.filter(&(&1.name == "monitor_setup.left"))

      assert left.properties == %{
               "step" => "purpose",
               "completed_count" => 1,
               "total_count" => 4
             }

      refute inspect(left) =~ "Sensitive customer purpose"
    end
  end

  describe "persisted steps" do
    test "accepts only a valid same-workspace credential matching the exact model provider", %{
      scope: scope,
      other_scope: other_scope
    } do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      pending = ProviderCredentialsFixtures.provider_credential_fixture(scope)
      other = MonitorSetupsFixtures.valid_credential_fixture(other_scope)
      valid = MonitorSetupsFixtures.valid_credential_fixture(scope)

      assert {:error, pending_changeset} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: pending.id,
                 provider: "openai",
                 requested_model: "gpt-5.6-luna"
               })

      assert "is not available" in errors_on(pending_changeset).provider_credential_id

      assert {:error, other_changeset} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: other.id,
                 provider: "openai",
                 requested_model: "gpt-5.6-luna"
               })

      assert "is not available" in errors_on(other_changeset).provider_credential_id

      assert {:error, model_changeset} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: valid.id,
                 provider: "openai",
                 requested_model: "gpt-5.6"
               })

      assert "is not allowlisted for this provider" in errors_on(model_changeset).requested_model

      assert {:ok, setup} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: valid.id,
                 provider: "openai",
                 requested_model: "gpt-5.6-luna"
               })

      assert setup.provider_credential_id == valid.id
      assert setup.provider == :openai
      assert MonitorSetups.progress(scope, setup).completed.connection
    end

    test "keeps both sides of a staged rotation unavailable to new monitors until activation", %{
      scope: scope
    } do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      predecessor = MonitorSetupsFixtures.valid_credential_fixture(scope)

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(scope, predecessor.id, %{
                 secret: "sk-test-successor-valid"
               })

      assert {:ok, _validated} =
               ProviderCredentials.validate_credential(scope, successor.id, %{
                 model: "gpt-5.6-luna"
               })

      assert ProviderCredentials.list_selectable_credentials(scope) == []

      for credential <- [predecessor, successor] do
        assert {:error, changeset} =
                 MonitorSetups.update_connection(scope, monitor.id, %{
                   provider_credential_id: credential.id,
                   provider: "openai",
                   requested_model: "gpt-5.6-luna"
                 })

        assert "has a pending replacement" in errors_on(changeset).provider_credential_id
      end

      assert {:ok, result} = ProviderCredentials.activate_replacement(scope, successor.id)
      assert result.affected_monitor_count == 0

      assert [selectable] = ProviderCredentials.list_selectable_credentials(scope)
      assert selectable.id == successor.id

      assert {:ok, setup} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: successor.id,
                 provider: "openai",
                 requested_model: "gpt-5.6-luna"
               })

      assert setup.provider_credential_id == successor.id
    end

    test "normalizes prompt configuration from form values and rejects invalid bounds", %{
      scope: scope
    } do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      connect_openai(scope, monitor)

      assert {:error, changeset} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: native_request_template(),
                 response_format: %{type: "text"},
                 generation_config: %{max_output_tokens: "9000"}
               })

      assert "contains an invalid value" in errors_on(changeset).generation_config

      assert {:ok, setup} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: native_request_template(),
                 response_format: %{type: "json_object"},
                 generation_config: %{
                   max_output_tokens: "512",
                   reasoning_effort: "low"
                 }
               })

      assert setup.response_format == %{"type" => "json_object"}
      assert setup.request_mode == :provider_native_v1
      assert setup.system_prompt == ""
      assert setup.user_prompt_template == ""

      assert setup.generation_config == %{
               "max_output_tokens" => 512,
               "reasoning_effort" => "low"
             }

      assert MonitorSetups.progress(scope, setup).completed.prompt
    end

    test "rejects generation settings unsupported by the selected model", %{scope: scope} do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      credential = MonitorSetupsFixtures.valid_credential_fixture(scope)

      assert {:ok, _setup} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: credential.id,
                 provider: :openai,
                 requested_model: "gpt-5.6-luna"
               })

      assert {:error, changeset} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: native_request_template(),
                 response_format: %{type: "text"},
                 generation_config: %{max_output_tokens: "512", temperature: "0"}
               })

      assert "temperature is not supported for the selected model; leave it blank to use the provider default" in errors_on(
               changeset
             ).generation_config
    end

    test "treats blank optional form settings as provider defaults", %{scope: scope} do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      connect_openai(scope, monitor)

      assert {:ok, setup} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: native_request_template(),
                 response_format: %{type: "text"},
                 generation_config: %{
                   max_output_tokens: "512",
                   temperature: "",
                   top_p: "",
                   reasoning_effort: ""
                 }
               })

      assert setup.generation_config == %{"max_output_tokens" => 512}
      assert MonitorSetups.progress(scope, setup).completed.prompt
    end

    test "preserves the explicitly marked legacy wrapper for migrated setup rows", %{scope: scope} do
      %{monitor: monitor, setup: setup} = MonitorSetupsFixtures.setup_fixture(scope)
      connect_openai(scope, monitor)

      setup
      |> Ecto.Changeset.change(request_mode: :legacy_wrapped_v1)
      |> Repo.update!()

      assert {:ok, setup} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 system_prompt: "Use only the context.",
                 user_prompt_template: "Question: {{question}}",
                 response_format: %{type: "text"},
                 generation_config: %{max_output_tokens: "512"}
               })

      assert setup.request_mode == :legacy_wrapped_v1
      assert setup.request_template == %{}
      assert setup.user_prompt_template == "Question: {{question}}"
    end

    test "requires a schema for provider-native Anthropic structured output", %{scope: scope} do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)

      credential =
        MonitorSetupsFixtures.valid_credential_fixture(scope, %{provider: :anthropic})

      assert {:ok, _setup} =
               MonitorSetups.update_connection(scope, monitor.id, %{
                 provider_credential_id: credential.id,
                 provider: :anthropic,
                 requested_model: "claude-haiku-4-5-20251001"
               })

      request_template = %{
        system: "Classify the request.",
        messages: [%{role: "user", content: "{{question}}"}]
      }

      assert {:error, changeset} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: request_template,
                 response_format: %{type: "json_object"},
                 generation_config: %{max_output_tokens: "128"}
               })

      assert "requires a JSON schema for provider-native Anthropic requests" in errors_on(
               changeset
             ).response_format

      assert {:ok, setup} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: request_template,
                 response_format: %{
                   type: "json_schema",
                   name: "classification",
                   schema_json:
                     ~s({"type":"object","properties":{"label":{"type":"string"}},"required":["label"],"additionalProperties":false}),
                   strict: "true"
                 },
                 generation_config: %{max_output_tokens: "128"}
               })

      assert setup.response_format["type"] == "json_schema"
      assert setup.response_format["schema"]["required"] == ["label"]
    end

    test "persists normalized manual cases and the same versioned JSON import", %{scope: scope} do
      %{monitor: manual_monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      %{monitor: import_monitor} = MonitorSetupsFixtures.setup_fixture(scope)

      manual = [
        %{
          case_key: "supported-answer",
          name: " Supported answer ",
          input_variables_json: ~s({"question":"Which plan includes SSO?"}),
          frozen_context: "Enterprise includes SSO.",
          expectation_json:
            Jason.encode!(%{
              checks: [
                %{id: "route", type: "label", allowed_values: ["approved"]}
              ]
            }),
          status: "active"
        }
      ]

      assert {:ok, manual_setup} =
               MonitorSetups.update_cases(scope, manual_monitor.id, manual)

      encoded =
        Jason.encode!(%{
          schema_version: 2,
          cases: [
            %{
              case_key: "supported-answer",
              name: " Supported answer ",
              input_variables: %{question: "Which plan includes SSO?"},
              frozen_context: "Enterprise includes SSO.",
              expectation: %{
                checks: [
                  %{id: "route", type: "label", allowed_values: ["approved"]}
                ]
              },
              status: "active"
            }
          ]
        })

      assert {:ok, import_setup} =
               MonitorSetups.import_cases(scope, import_monitor.id, encoded)

      assert MonitorSetups.stored_cases(manual_setup) ==
               MonitorSetups.stored_cases(import_setup)

      assert [stored_case] = MonitorSetups.stored_cases(manual_setup)
      assert stored_case["expectation_schema_version"] == "case_expectation_v1"

      assert MonitorSetups.progress(scope, manual_setup).completed.cases
    end

    test "rejects cases that cannot render the saved provider request", %{scope: scope} do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      connect_openai(scope, monitor)

      assert {:ok, _setup} =
               MonitorSetups.update_prompt(scope, monitor.id, %{
                 request_template: native_request_template(),
                 response_format: %{type: "text"},
                 generation_config: %{max_output_tokens: "128"}
               })

      assert {:error, changeset} =
               MonitorSetups.update_cases(scope, monitor.id, [
                 %{
                   case_key: "missing-question",
                   name: "Missing question",
                   input_variables_json: "{}",
                   frozen_context: "Evidence",
                   status: "active"
                 }
               ])

      assert "contain invalid or incomplete data" in errors_on(changeset).cases
    end
  end

  describe "completion" do
    test "atomically promotes a complete setup without provider execution", %{scope: scope} do
      completed = MonitorSetupsFixtures.complete_setup_fixture(scope)

      assert completed.setup.status == :completed
      assert completed.setup.completed_monitor_version_id == completed.version.id
      assert completed.version.status == :draft
      assert length(completed.version.cases) == 1

      assert {:ok, monitor} = Monitors.get_monitor(scope, completed.monitor.id)
      assert monitor.provider_credential_id == completed.credential.id
      assert monitor.draft_version_id == completed.version.id
      assert monitor.state == :draft

      assert MonitorSetups.progress(scope, completed.setup).ready?

      [completion] =
        scope
        |> ProductAnalytics.list_events()
        |> Enum.filter(&(&1.name == "monitor_setup.completed"))

      assert completion.properties == %{"completed_count" => 4, "total_count" => 4}
      refute inspect(completion) =~ "Answer only from the supplied context."
    end

    test "rejects incomplete and repeated promotion", %{scope: scope} do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)
      assert {:error, :setup_incomplete} = MonitorSetups.complete(scope, monitor.id)
      assert [] = Monitors.list_versions(scope, monitor.id)

      completed = MonitorSetupsFixtures.complete_setup_fixture(scope)
      assert {:error, :already_completed} = MonitorSetups.complete(scope, completed.monitor.id)
    end
  end

  describe "tenancy and event safety" do
    test "setup reads and mutations are workspace scoped", %{
      scope: scope,
      other_scope: other_scope
    } do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)

      assert {:error, :not_found} = MonitorSetups.get(other_scope, monitor.id)

      assert {:error, :not_found} =
               MonitorSetups.update_prompt(other_scope, monitor.id, %{
                 user_prompt_template: "Intrusion"
               })

      assert {:error, :not_found} = MonitorSetups.complete(other_scope, monitor.id)
      assert [] = MonitorSetups.list(other_scope)
      assert [] = ProductAnalytics.list_events(other_scope)
    end

    test "product event properties are allowlisted and event content is immutable", %{
      scope: scope
    } do
      %{monitor: monitor} = MonitorSetupsFixtures.setup_fixture(scope)

      assert_raise ArgumentError, ~r/invalid product event/, fn ->
        ProductAnalytics.record!(scope, "monitor_setup.left", monitor.id, %{
          "step" => "cases",
          "prompt" => "must not leak"
        })
      end

      event = ProductAnalytics.list_events(scope) |> hd()

      assert_raise Postgrex.Error, ~r/product event content is immutable/, fn ->
        event
        |> Ecto.Changeset.change(properties: %{"step" => "review"})
        |> Repo.update!()
      end
    end

    test "completed setup rows obey database state consistency", %{scope: scope} do
      %{setup: setup} = MonitorSetupsFixtures.setup_fixture(scope)

      assert {:error, changeset} =
               setup
               |> Ecto.Changeset.change(
                 status: :completed,
                 completed_at: DateTime.utc_now(:second)
               )
               |> Ecto.Changeset.check_constraint(:status,
                 name: :monitor_setups_completion_check
               )
               |> Repo.update()

      assert %{status: [_message]} = errors_on(changeset)
      assert Repo.get!(Setup, setup.id).status == :in_progress
    end
  end

  describe "configuration successors" do
    test "a reviewed missed regression adds a case and returns through replacement reference", %{
      scope: scope
    } do
      fixture = operational_monitor_fixture(scope)
      source_monitor = Repo.get!(Monitor, fixture.monitor.id)
      source_version = Repo.get!(MonitorVersion, source_monitor.active_version_id)
      source_contract = Repo.get!(ContractVersion, fixture.contract.id)
      source_credential_id = source_monitor.provider_credential_id

      assert {:ok, planned_run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert {:ok, run} = Captures.get_run(scope, planned_run.id)

      Enum.each(run.observations, fn item ->
        assert :ok = Captures.execute_observation(run.id, item.id)
      end)

      [observation] = run.observations

      assert {:ok, review} =
               Reviews.submit_review(scope, %{
                 subject_kind: :observation,
                 subject_id: observation.id,
                 classification: :passed_but_should_have_failed,
                 action: :case_change,
                 rationale: "Add the missing refund-policy case.",
                 reviewed_at: DateTime.utc_now(),
                 expected_current_id: nil
               })

      assert {:ok, setup} =
               MonitorSetups.start_successor(scope, fixture.monitor.id, review.id)

      assert setup.status == :in_progress
      assert setup.source_monitor_version_id == source_version.id
      assert setup.motivating_review_decision_id == review.id
      assert setup.provider_credential_id == source_credential_id

      active_during_edit = Repo.get!(Monitor, fixture.monitor.id)
      assert active_during_edit.active_version_id == source_version.id
      assert active_during_edit.state == :active
      assert active_during_edit.draft_version_id == nil
      assert {:ok, _baseline} = Baselines.current_compatible(scope, fixture.monitor.id)

      cases =
        MonitorSetups.stored_cases(setup) ++
          [
            %{
              case_key: "refund-policy",
              name: "Refund policy answer",
              input_variables_json: Jason.encode!(%{question: "Is this refundable?"}),
              frozen_context: "The purchase is refundable.",
              expectation_json:
                Jason.encode!(%{
                  checks: [
                    %{id: "route", type: "label", allowed_values: ["approved"]}
                  ]
                }),
              status: "active"
            }
          ]

      assert {:ok, _setup} = MonitorSetups.update_cases(scope, fixture.monitor.id, cases)
      assert {:ok, completed} = MonitorSetups.complete(scope, fixture.monitor.id)
      candidate = completed.version

      assert candidate.status == :draft
      assert candidate.predecessor_id == source_version.id

      assert Repo.aggregate(
               from(case_version in CaseVersion,
                 where: case_version.monitor_version_id == ^candidate.id
               ),
               :count
             ) == 2

      still_active = Repo.get!(Monitor, fixture.monitor.id)
      assert still_active.active_version_id == source_version.id
      assert still_active.draft_version_id == candidate.id
      assert still_active.provider_credential_id == source_credential_id
      assert still_active.state == :active
      assert Repo.get!(ContractVersion, source_contract.id).status == :approved
      assert {:ok, _baseline} = Baselines.current_compatible(scope, fixture.monitor.id)

      assert {:ok, state} = MonitorSetups.successor_state(scope, fixture.monitor.id)
      assert state.setup.motivating_review_decision_id == review.id
      assert state.preview.activation_ready?
      assert state.preview.changes == [:cases]

      assert {:error, :stale_preview} =
               MonitorSetups.activate_successor(scope, fixture.monitor.id, "stale")

      assert Repo.get!(Monitor, fixture.monitor.id).active_version_id == source_version.id

      assert {:ok, activated} =
               MonitorSetups.activate_successor(
                 scope,
                 fixture.monitor.id,
                 state.preview.fingerprint
               )

      assert activated.monitor.state == :baseline_pending
      assert activated.monitor.active_version_id == candidate.id
      assert activated.monitor.draft_version_id == nil
      assert activated.monitor.cadence == :manual
      assert Repo.get!(MonitorVersion, source_version.id).status == :superseded
      assert Repo.get!(ContractVersion, source_contract.id).status == :retired
      assert activated.contract_version.status == :approved
      assert activated.contract_version.monitor_version_id == candidate.id

      assert activated.contract_version.contract_fingerprint ==
               source_contract.contract_fingerprint

      assert activated.contract_version.proof_fingerprint == source_contract.proof_fingerprint

      assert {:error, :incompatible_baseline} =
               Baselines.current_compatible(scope, fixture.monitor.id)

      assert {:ok, preflight} = Baselines.preflight(scope, fixture.monitor.id)

      assert {:ok, snapshot} =
               Baselines.authorize(scope, fixture.monitor.id, %{
                 authorization_key: Ecto.UUID.generate(),
                 samples_per_case: preflight.samples_per_case,
                 preview_fingerprint: preflight.preview_fingerprint
               })

      Enum.each(snapshot.capture_run.observations, fn item ->
        assert :ok = Captures.execute_observation(snapshot.capture_run.id, item.id)
      end)

      assert {:ok, _approved} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

      assert {:ok, restored} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

      assert restored.state == :active
      assert restored.active_version_id == candidate.id
    end

    test "only owners can start or activate and foreign workspaces cannot inspect", %{
      scope: owner_scope,
      other_scope: other_scope
    } do
      fixture = operational_monitor_fixture(owner_scope)
      member = WorkspacesFixtures.invite_and_accept_member(owner_scope)

      member_scope =
        SilentRegression.Accounts.Scope.for_workspace(
          member.user,
          member.workspace,
          member.membership
        )

      assert {:error, :owner_required} =
               MonitorSetups.start_successor(member_scope, fixture.monitor.id)

      assert {:ok, _setup} = MonitorSetups.start_successor(owner_scope, fixture.monitor.id)

      assert {:error, :not_found} =
               MonitorSetups.successor_state(other_scope, fixture.monitor.id)
    end
  end

  defp connect_openai(scope, monitor) do
    credential = MonitorSetupsFixtures.valid_credential_fixture(scope)

    {:ok, _setup} =
      MonitorSetups.update_connection(scope, monitor.id, %{
        provider_credential_id: credential.id,
        provider: :openai,
        requested_model: "gpt-5.6-luna"
      })

    credential
  end

  defp native_request_template do
    %{
      instructions: "Use only the context.",
      input: [
        %{
          role: "user",
          content: "Context: {{frozen_context}}\nQuestion: {{question}}"
        }
      ]
    }
  end
end
