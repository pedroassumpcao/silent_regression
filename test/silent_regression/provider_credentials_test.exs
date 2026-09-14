defmodule SilentRegression.ProviderCredentialsTest do
  use SilentRegression.DataCase, async: true

  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.ProviderCredentials
  alias SilentRegression.ProviderCredentials.ProviderCredential
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
    test "rotation creates a successor and preserves the superseded identity" do
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

      assert {:ok, superseded} = ProviderCredentials.get_credential(scope, old.id)
      assert superseded.status == :superseded
      assert superseded.superseded_at

      assert {:error, :not_active} =
               ProviderCredentials.rotate_credential(scope, old.id, %{
                 secret: "sk-ant-test-second-rotation"
               })

      assert MapSet.new(event_actions(scope)) ==
               MapSet.new([
                 "provider_credential.created",
                 "provider_credential.rotated",
                 "provider_credential.superseded"
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
