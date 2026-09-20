defmodule SilentRegression.ProviderCredentialsTest do
  use SilentRegression.DataCase, async: false

  import ExUnit.CaptureLog
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorsFixtures
  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.Baselines
  alias SilentRegression.Captures
  alias SilentRegression.Captures.{CaptureObservation, ProviderAttempt}
  alias SilentRegression.MonitorOperations
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.ProviderCredentials
  alias SilentRegression.ProviderCredentials.{ModelValidation, ProviderCredential}
  alias SilentRegression.Repo

  describe "create_credential/2 and safe reads" do
    test "owners store encrypted secrets and receive only safe metadata" do
      scope = workspace_scope_fixture()
      plaintext = "sk-test-plaintext-storage-sentinel"

      assert {:ok, credential} =
               ProviderCredentials.create_credential(scope, %{
                 provider: :openai,
                 label: " Production key ",
                 secret: "  #{plaintext}  "
               })

      assert credential.provider == :openai
      assert credential.label == "Production key"
      assert credential.secret_suffix == "inel"
      assert credential.status == :pending_validation
      refute Map.has_key?(credential, :secret)

      stored = Repo.get!(ProviderCredential, credential.id)
      assert stored.secret == plaintext
      refute inspect(stored) =~ plaintext
      refute inspect(stored) =~ "secret:"

      %{rows: [[ciphertext]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT encrypted_secret FROM provider_credentials WHERE id = $1",
          [Ecto.UUID.dump!(credential.id)]
        )

      refute ciphertext == plaintext
      assert :binary.match(ciphertext, plaintext) == :nomatch

      assert [listed] = ProviderCredentials.list_credentials(scope)
      assert listed.id == credential.id
      refute Map.has_key?(listed, :secret)

      assert {:ok, fetched} = ProviderCredentials.get_credential(scope, credential.id)
      assert fetched == listed
    end

    test "suppresses plaintext credential values from Ecto query logs" do
      scope = workspace_scope_fixture()
      plaintext = "sk-test-query-log-plaintext-sentinel"

      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          assert {:ok, _credential} =
                   ProviderCredentials.create_credential(scope, %{
                     provider: :openai,
                     label: "Log-safe key",
                     secret: plaintext
                   })
        end)

      assert log =~ ~s(source="audit_events")
      refute log =~ plaintext
    end

    test "validates bounded attributes without leaking the submitted secret" do
      scope = workspace_scope_fixture()
      secret = "short"

      assert {:error, %Ecto.Changeset{} = changeset} =
               ProviderCredentials.create_credential(scope, %{
                 provider: :unsupported,
                 label: "",
                 secret: secret
               })

      assert "can't be blank" in errors_on(changeset).label
      assert "should be at least 8 character(s)" in errors_on(changeset).secret
      assert "is invalid" in errors_on(changeset).provider
      refute inspect(changeset) =~ secret
      assert inspect(changeset) =~ ~s(secret: "**redacted**")
    end
  end

  describe "owner and member authorization" do
    setup do
      accepted = accepted_workspace_fixture()
      owner_scope = Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      %{owner_scope: owner_scope, member_scope: member_scope}
    end

    test "members can see safe metadata but cannot administer credentials", %{
      owner_scope: owner_scope,
      member_scope: member_scope
    } do
      credential = provider_credential_fixture(owner_scope)

      assert [listed] = ProviderCredentials.list_credentials(member_scope)
      assert listed.id == credential.id
      refute Map.has_key?(listed, :secret)

      assert {:error, :owner_required} =
               ProviderCredentials.create_credential(
                 member_scope,
                 valid_provider_credential_attributes()
               )

      assert {:error, :owner_required} =
               ProviderCredentials.rotate_credential(member_scope, credential.id, %{
                 secret: "sk-member-must-not-rotate"
               })

      assert {:error, :owner_required} =
               ProviderCredentials.revoke_credential(member_scope, credential.id)
    end

    test "every read and mutation is isolated by workspace", %{owner_scope: owner_scope} do
      credential = provider_credential_fixture(owner_scope)
      other_scope = workspace_scope_fixture()

      assert [] = ProviderCredentials.list_credentials(other_scope)

      assert {:error, :not_found} =
               ProviderCredentials.get_credential(other_scope, credential.id)

      assert {:error, :not_found} =
               ProviderCredentials.rotate_credential(other_scope, credential.id, %{
                 secret: "sk-other-workspace-cannot-rotate"
               })

      assert {:error, :not_found} =
               ProviderCredentials.revoke_credential(other_scope, credential.id)
    end
  end

  describe "rotation and revocation" do
    test "rotation stages a successor without disabling the predecessor" do
      scope = workspace_scope_fixture()
      old = provider_credential_fixture(scope, %{provider: :anthropic, label: "Claude"})

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(scope, old.id, %{
                 secret: "sk-ant-test-rotated-secret"
               })

      assert successor.id != old.id
      assert successor.provider == :anthropic
      assert successor.label == "Claude"
      assert successor.supersedes_id == old.id
      assert successor.status == :pending_validation

      assert {:ok, predecessor} = ProviderCredentials.get_credential(scope, old.id)
      assert predecessor.status == :pending_validation
      assert predecessor.superseded_at == nil

      assert {:error, :replacement_pending} =
               ProviderCredentials.rotate_credential(scope, old.id, %{
                 secret: "sk-ant-test-second-rotation"
               })

      assert MapSet.new(event_actions(scope)) ==
               MapSet.new([
                 "provider_credential.created",
                 "provider_credential.rotated"
               ])
    end

    test "revocation is terminal for lifecycle operations" do
      scope = workspace_scope_fixture()
      credential = provider_credential_fixture(scope)

      assert {:ok, revoked} = ProviderCredentials.revoke_credential(scope, credential.id)
      assert revoked.status == :revoked
      assert revoked.revoked_at

      assert {:error, :not_active} =
               ProviderCredentials.revoke_credential(scope, credential.id)

      assert {:error, :not_active} =
               ProviderCredentials.rotate_credential(scope, credential.id, %{
                 secret: "sk-test-cannot-rotate-revoked"
               })

      assert "provider_credential.revoked" in event_actions(scope)
    end

    test "revoking a staged successor releases the predecessor for a replacement retry" do
      scope = workspace_scope_fixture()
      predecessor = provider_credential_fixture(scope)
      assert {:ok, _validated} = ProviderCredentials.validate_credential(scope, predecessor.id)

      assert {:ok, first_successor} =
               ProviderCredentials.rotate_credential(scope, predecessor.id, %{
                 secret: "sk-test-first-successor"
               })

      assert {:ok, _validated} =
               ProviderCredentials.validate_credential(scope, first_successor.id)

      assert ProviderCredentials.list_selectable_credentials(scope) == []
      assert {:ok, revoked} = ProviderCredentials.revoke_credential(scope, first_successor.id)
      assert revoked.status == :revoked

      assert [selectable] = ProviderCredentials.list_selectable_credentials(scope)
      assert selectable.id == predecessor.id

      assert {:ok, second_successor} =
               ProviderCredentials.rotate_credential(scope, predecessor.id, %{
                 secret: "sk-test-second-successor"
               })

      assert second_successor.supersedes_id == predecessor.id
      assert second_successor.id != first_successor.id
    end
  end

  describe "validate_credential/3" do
    test "persists successful, content-free provider provenance" do
      scope = workspace_scope_fixture()

      credential =
        provider_credential_fixture(scope, %{
          provider: :anthropic,
          secret: "sk-ant-test-valid-credential"
        })

      assert {:ok, validated} =
               ProviderCredentials.validate_credential(scope, credential.id, %{
                 model: "claude-test"
               })

      assert validated.status == :valid
      assert validated.last_validation_status == :succeeded
      assert validated.last_failure_category == nil
      assert validated.last_requested_model == "claude-test"
      assert validated.last_returned_model == "claude-test"
      assert validated.last_provider_request_id == "fake_anthropic_validation_request"
      assert validated.last_validation_attempts == 1
      assert validated.last_validated_at
      refute Map.has_key?(validated, :secret)

      model_validation =
        Repo.get_by!(ModelValidation,
          provider_credential_id: credential.id,
          requested_model: "claude-test"
        )

      assert model_validation.status == :succeeded
      assert model_validation.returned_model == "claude-test"

      assert ProviderCredentials.model_access_verified?(
               Repo.get!(ProviderCredential, credential.id),
               "claude-test"
             )

      event =
        scope
        |> Audit.list_workspace_events()
        |> Enum.find(&(&1.action == "provider_credential.validation_succeeded"))

      assert event.metadata == %{
               "attempts" => 1,
               "provider" => "anthropic",
               "provider_request_id" => "fake_anthropic_validation_request",
               "requested_model" => "claude-test",
               "returned_model" => "claude-test"
             }
    end

    test "authentication failure invalidates the credential without exposing its secret" do
      scope = workspace_scope_fixture()
      secret = "sk-test-authentication-error"
      credential = provider_credential_fixture(scope, %{secret: secret})

      assert {:error, failure} =
               ProviderCredentials.validate_credential(scope, credential.id)

      assert failure.category == :authentication
      refute inspect(failure) =~ secret

      assert {:ok, invalid} = ProviderCredentials.get_credential(scope, credential.id)
      assert invalid.status == :invalid
      assert invalid.last_validation_status == :failed
      assert invalid.last_failure_category == :authentication
      assert invalid.last_provider_request_id == "fake_authentication_request"

      event =
        scope
        |> Audit.list_workspace_events()
        |> Enum.find(&(&1.action == "provider_credential.validation_failed"))

      assert event.metadata["category"] == "authentication"
      refute inspect(event) =~ secret
    end

    test "transient validation failure does not declare a pending credential invalid" do
      scope = workspace_scope_fixture()
      credential = provider_credential_fixture(scope, %{secret: "sk-test-rate-limited"})

      assert {:error, failure} =
               ProviderCredentials.validate_credential(scope, credential.id)

      assert failure.category == :rate_limited

      assert {:ok, pending} = ProviderCredentials.get_credential(scope, credential.id)
      assert pending.status == :pending_validation
      assert pending.last_validation_status == :failed
      assert pending.last_failure_category == :rate_limited
    end

    test "a returned model mismatch is persisted as failed exact-model proof" do
      scope = workspace_scope_fixture()

      credential =
        provider_credential_fixture(scope, %{
          secret: "sk-test-validation-model-mismatch"
        })

      assert {:error, failure} =
               ProviderCredentials.validate_credential(scope, credential.id, %{
                 model: "gpt-5.6-luna"
               })

      assert failure.category == :model_mismatch
      assert failure.requested_model == "gpt-5.6-luna"
      assert failure.returned_model == "gpt-5.6-luna-unexpected"

      validation =
        Repo.get_by!(ModelValidation,
          provider_credential_id: credential.id,
          requested_model: "gpt-5.6-luna"
        )

      assert validation.status == :failed
      assert validation.failure_category == :model_mismatch

      refute ProviderCredentials.model_access_verified?(
               Repo.get!(ProviderCredential, credential.id),
               "gpt-5.6-luna"
             )
    end

    test "members and other workspaces cannot trigger provider validation" do
      accepted = accepted_workspace_fixture()
      owner_scope = Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)
      credential = provider_credential_fixture(owner_scope)

      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
      other_scope = workspace_scope_fixture()

      assert {:error, :owner_required} =
               ProviderCredentials.validate_credential(member_scope, credential.id)

      assert {:error, :not_found} =
               ProviderCredentials.validate_credential(other_scope, credential.id)
    end

    test "rejects invalid requested model metadata before validation" do
      scope = workspace_scope_fixture()
      credential = provider_credential_fixture(scope)

      assert {:error, :invalid_model} =
               ProviderCredentials.validate_credential(scope, credential.id, %{model: 123})

      assert {:ok, unchanged} = ProviderCredentials.get_credential(scope, credential.id)
      assert unchanged.status == :pending_validation
      assert unchanged.last_validation_status == nil
    end
  end

  describe "activate_replacement/2" do
    test "validates all affected models and atomically rebinds only future execution" do
      scope = workspace_scope_fixture()
      fixture = operational_monitor_fixture(scope)
      predecessor = Repo.get!(ProviderCredential, fixture.credential.id)

      second_monitor = monitor_fixture(scope, %{name: "Second model monitor"})

      _second_version =
        version_fixture(scope, second_monitor, %{requested_model: "gpt-5.6-sol"})

      second_monitor
      |> Monitor.credential_changeset(predecessor)
      |> Repo.update!()

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(scope, predecessor.id, %{
                 secret: "sk-test-successor-valid"
               })

      overviews = ProviderCredentials.list_credential_overviews(scope)
      predecessor_overview = Enum.find(overviews, &(&1.id == predecessor.id))
      successor_overview = Enum.find(overviews, &(&1.id == successor.id))

      assert predecessor_overview.successor_id == successor.id

      assert Enum.map(predecessor_overview.attached_monitors, & &1.id) |> Enum.sort() ==
               Enum.sort([fixture.monitor.id, second_monitor.id])

      assert Enum.sort(
               Enum.flat_map(successor_overview.replacement_impact, & &1.requested_models)
             ) ==
               ["gpt-5.6-luna", "gpt-5.6-sol"]

      assert Enum.any?(
               successor_overview.replacement_impact,
               &(&1.id == fixture.monitor.id and &1.reference_replacement_required)
             )

      assert {:ok, result} = ProviderCredentials.activate_replacement(scope, successor.id)
      assert result.affected_monitor_count == 2
      assert result.requested_models == ["gpt-5.6-luna", "gpt-5.6-sol"]
      assert result.reference_replacement_count == 1

      assert {:ok, superseded} = ProviderCredentials.get_credential(scope, predecessor.id)
      assert superseded.status == :superseded
      assert superseded.superseded_at

      assert {:ok, activated} = ProviderCredentials.get_credential(scope, successor.id)
      assert activated.status == :valid

      assert ProviderCredentials.verified_models(Repo.get!(ProviderCredential, successor.id)) == [
               "gpt-5.6-luna",
               "gpt-5.6-sol"
             ]

      active_monitor = Repo.get!(Monitor, fixture.monitor.id)
      assert active_monitor.provider_credential_id == successor.id
      assert active_monitor.state == :paused
      assert active_monitor.pause_reason == :incompatible_configuration
      assert active_monitor.next_run_at == nil

      draft_monitor = Repo.get!(Monitor, second_monitor.id)
      assert draft_monitor.provider_credential_id == successor.id
      assert draft_monitor.state == :draft

      assert Repo.get!(SilentRegression.Baselines.BaselineSnapshot, fixture.baseline.id).provider_credential_id ==
               predecessor.id

      assert Repo.get!(SilentRegression.Captures.CaptureRun, fixture.baseline.capture_run_id).provider_credential_id ==
               predecessor.id

      assert {:error, :incompatible_baseline} =
               Baselines.current_compatible(scope, fixture.monitor.id)

      assert {:ok, state} = Baselines.get_state(scope, fixture.monitor.id)
      assert state.preflight.replacement?
      assert state.preflight.ready?
      assert :provider_credential_id in state.compatibility.mismatches

      assert {:ok, replacement_baseline} =
               Baselines.authorize(scope, fixture.monitor.id, %{
                 authorization_key: Ecto.UUID.generate(),
                 samples_per_case: state.preflight.samples_per_case,
                 preview_fingerprint: state.preflight.preview_fingerprint
               })

      Enum.each(replacement_baseline.capture_run.observations, fn observation ->
        assert :ok =
                 Captures.execute_observation(
                   replacement_baseline.capture_run_id,
                   observation.id
                 )
      end)

      assert {:ok, approved_replacement} =
               Baselines.approve(scope, fixture.monitor.id, %{approval_mode: :normal})

      assert approved_replacement.provider_credential_id == successor.id

      assert {:ok, resumed} =
               MonitorOperations.configure(scope, fixture.monitor.id, %{cadence: :manual})

      assert resumed.state == :active
      assert resumed.pause_reason == nil

      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert run.provider_credential_id == successor.id
      assert run.maximum_call_count == 2

      [observation] =
        Repo.all(
          from observation in CaptureObservation,
            where: observation.capture_run_id == ^run.id
        )

      assert :ok = Captures.execute_observation(run.id, observation.id)
      assert {:ok, completed_run} = Captures.get_run(scope, run.id)
      assert completed_run.status == :succeeded

      assert Repo.aggregate(
               from(attempt in ProviderAttempt, where: attempt.capture_run_id == ^run.id),
               :count
             ) == 1

      actions = scope |> Audit.list_workspace_events() |> Enum.map(& &1.action)
      assert "provider_credential.superseded" in actions
      assert "provider_credential.replacement_activated" in actions
      assert Enum.count(actions, &(&1 == "monitor.credential_rebound")) == 2
    end

    test "blocks cutover while an affected run is in progress" do
      scope = workspace_scope_fixture()
      fixture = operational_monitor_fixture(scope)

      assert {:ok, run} = MonitorOperations.run_now(scope, fixture.monitor.id)
      assert run.status == :queued

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(scope, fixture.credential.id, %{
                 secret: "sk-test-successor-valid"
               })

      assert {:error, :replacement_work_in_progress} =
               ProviderCredentials.activate_replacement(scope, successor.id)

      assert Repo.get!(Monitor, fixture.monitor.id).provider_credential_id ==
               fixture.credential.id

      assert Repo.get!(ProviderCredential, fixture.credential.id).status == :valid
      assert Repo.get!(ProviderCredential, successor.id).status == :pending_validation

      refute Repo.exists?(
               from validation in ModelValidation,
                 where: validation.provider_credential_id == ^successor.id
             )
    end

    test "blocks cutover while an affected baseline decision is pending" do
      scope = workspace_scope_fixture()
      fixture = baseline_ready_monitor_fixture(scope)
      assert {:ok, preflight} = Baselines.preflight(scope, fixture.monitor.id)

      assert {:ok, snapshot} =
               Baselines.authorize(scope, fixture.monitor.id, %{
                 authorization_key: Ecto.UUID.generate(),
                 samples_per_case: preflight.samples_per_case,
                 preview_fingerprint: preflight.preview_fingerprint
               })

      assert {:ok, cancelled_run} = Captures.cancel_run(scope, snapshot.capture_run_id)
      assert cancelled_run.status == :cancelled

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(scope, fixture.credential.id, %{
                 secret: "sk-test-successor-valid"
               })

      assert {:error, :replacement_work_in_progress} =
               ProviderCredentials.activate_replacement(scope, successor.id)

      assert Repo.get!(Monitor, fixture.monitor.id).provider_credential_id ==
               fixture.credential.id

      assert Repo.get!(ProviderCredential, successor.id).status == :pending_validation

      refute Repo.exists?(
               from validation in ModelValidation,
                 where: validation.provider_credential_id == ^successor.id
             )
    end

    test "recovers a legacy lineage whose predecessor was already superseded" do
      scope = workspace_scope_fixture()
      fixture = operational_monitor_fixture(scope)

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(scope, fixture.credential.id, %{
                 secret: "sk-test-legacy-successor-valid"
               })

      fixture.credential.id
      |> then(&Repo.get!(ProviderCredential, &1))
      |> ProviderCredential.supersede_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:ok, result} = ProviderCredentials.activate_replacement(scope, successor.id)
      assert result.affected_monitor_count == 1
      assert Repo.get!(Monitor, fixture.monitor.id).provider_credential_id == successor.id
      assert Repo.get!(ProviderCredential, fixture.credential.id).status == :superseded
    end

    test "members cannot inspect replacement impact through a mutation or activate it" do
      owner_scope = workspace_scope_fixture()
      credential = provider_credential_fixture(owner_scope)

      assert {:ok, successor} =
               ProviderCredentials.rotate_credential(owner_scope, credential.id, %{
                 secret: "sk-test-successor-valid"
               })

      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)

      assert {:error, :owner_required} =
               ProviderCredentials.activate_replacement(member_scope, successor.id)
    end
  end

  test "provider and lifecycle sets remain deliberately bounded" do
    assert ProviderCredential.providers() == [:openai, :anthropic]

    assert ProviderCredential.statuses() == [
             :pending_validation,
             :valid,
             :invalid,
             :revoked,
             :superseded
           ]
  end

  defp event_actions(scope) do
    scope
    |> Audit.list_workspace_events()
    |> Enum.map(& &1.action)
    |> Enum.filter(&String.starts_with?(&1, "provider_credential."))
  end
end
