defmodule SilentRegressionWeb.ProviderCredentialControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.ProviderCredentials

  setup :register_and_log_in_workspace

  describe "GET /app/:workspace_slug/credentials" do
    test "renders safe owner credential props without plaintext", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      plaintext = "sk-test-controller-plaintext-sentinel"
      credential = provider_credential_fixture(scope, %{secret: plaintext})

      conn = get(conn, ~p"/app/#{workspace.slug}/credentials")

      assert html_response(conn, 200)
      assert inertia_component(conn) == "Credentials/Index"
      assert inertia_props(conn).canManage
      assert inertia_props(conn).pageTitle == "Provider credentials"

      assert [prop] = inertia_props(conn).credentials
      assert prop.id == credential.id
      assert prop.secretSuffix == "inel"
      refute Map.has_key?(prop, :secret)
      refute inspect(inertia_props(conn)) =~ plaintext
    end

    test "requires authentication and a workspace membership", %{
      workspace: workspace
    } do
      conn = build_conn() |> get(~p"/app/#{workspace.slug}/credentials")
      assert redirected_to(conn) == ~p"/users/log-in"

      outsider = accepted_workspace_fixture()

      unauthorized =
        build_conn()
        |> log_in_user(outsider.user)
        |> get(~p"/app/#{workspace.slug}/credentials")

      assert response(unauthorized, 404) == "Not found"
    end
  end

  describe "owner lifecycle actions" do
    test "Phoenix filters nested credential secrets before logging request parameters" do
      plaintext = "sk-test-request-log-plaintext-sentinel"

      assert %{
               "provider_credential" => %{"label" => "Production", "secret" => "[FILTERED]"}
             } =
               Phoenix.Logger.filter_values(%{
                 "provider_credential" => %{
                   "label" => "Production",
                   "secret" => plaintext
                 }
               })
    end

    test "creates, validates, rotates, and revokes without returning a secret", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      created =
        post(conn, ~p"/app/#{workspace.slug}/credentials", %{
          "provider_credential" => %{
            "provider" => "anthropic",
            "label" => "Production Claude",
            "secret" => "sk-ant-test-controller-valid"
          }
        })

      assert redirected_to(created) == ~p"/app/#{workspace.slug}/credentials"
      assert Phoenix.Flash.get(created.assigns.flash, :info) =~ "stored"
      assert [credential] = ProviderCredentials.list_credentials(scope)

      validated =
        created
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/credentials/#{credential.id}/validate")

      assert redirected_to(validated) == ~p"/app/#{workspace.slug}/credentials"
      assert Phoenix.Flash.get(validated.assigns.flash, :info) =~ "validated"

      assert {:ok, valid} = ProviderCredentials.get_credential(scope, credential.id)
      assert valid.status == :valid
      assert valid.last_returned_model == "fake-anthropic-model"

      rotated =
        validated
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/credentials/#{credential.id}/rotate", %{
          "provider_credential" => %{"secret" => "sk-ant-test-controller-rotated"}
        })

      assert redirected_to(rotated) == ~p"/app/#{workspace.slug}/credentials"
      assert Phoenix.Flash.get(rotated.assigns.flash, :info) =~ "Replacement stored"

      successor =
        scope
        |> ProviderCredentials.list_credentials()
        |> Enum.find(&(&1.supersedes_id == credential.id))

      activated =
        rotated
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/credentials/#{successor.id}/activate-replacement")

      assert redirected_to(activated) == ~p"/app/#{workspace.slug}/credentials"
      assert Phoenix.Flash.get(activated.assigns.flash, :info) =~ "activated"

      assert {:ok, superseded} = ProviderCredentials.get_credential(scope, credential.id)
      assert superseded.status == :superseded

      revoked =
        activated
        |> recycle()
        |> delete(~p"/app/#{workspace.slug}/credentials/#{successor.id}")

      assert redirected_to(revoked) == ~p"/app/#{workspace.slug}/credentials"
      assert Phoenix.Flash.get(revoked.assigns.flash, :info) =~ "revoked"

      assert {:ok, revoked_credential} =
               ProviderCredentials.get_credential(scope, successor.id)

      assert revoked_credential.status == :revoked
    end

    test "returns changeset errors and clears no server-side secret into props", %{
      conn: conn,
      workspace: workspace
    } do
      invalid =
        post(conn, ~p"/app/#{workspace.slug}/credentials", %{
          "provider_credential" => %{
            "provider" => "openai",
            "label" => "",
            "secret" => "short"
          }
        })

      assert redirected_to(invalid) == ~p"/app/#{workspace.slug}/credentials"

      page = invalid |> recycle() |> get(~p"/app/#{workspace.slug}/credentials")
      assert inertia_props(page).errors.label == "can't be blank"
      assert inertia_props(page).errors.secret =~ "at least 8"
      refute inspect(inertia_props(page)) =~ "short"
    end

    test "persists a safe failure and shows a normalized message", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      credential =
        provider_credential_fixture(scope, %{secret: "sk-test-authentication-error"})

      rejected =
        post(conn, ~p"/app/#{workspace.slug}/credentials/#{credential.id}/validate")

      assert redirected_to(rejected) == ~p"/app/#{workspace.slug}/credentials"
      assert Phoenix.Flash.get(rejected.assigns.flash, :error) =~ "fake OpenAI"

      assert {:ok, invalid} = ProviderCredentials.get_credential(scope, credential.id)
      assert invalid.status == :invalid
      assert invalid.last_failure_category == :authentication
    end

    test "malformed and cross-workspace credential IDs return the same 404", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      other_scope = workspace_scope_fixture()
      other_credential = provider_credential_fixture(other_scope)

      malformed = post(conn, ~p"/app/#{workspace.slug}/credentials/not-a-uuid/validate")

      missing =
        build_conn()
        |> log_in_user(scope.user)
        |> post(~p"/app/#{workspace.slug}/credentials/#{other_credential.id}/validate")

      assert response(malformed, 404) == "Not found"
      assert response(missing, 404) == "Not found"
    end
  end

  describe "member authorization" do
    test "members receive safe metadata but every lifecycle action is forbidden", %{
      scope: owner_scope,
      workspace: workspace
    } do
      credential = provider_credential_fixture(owner_scope)
      member = invite_and_accept_member(owner_scope)
      member_scope = Scope.for_workspace(member.user, member.workspace, member.membership)
      member_conn = build_conn() |> log_in_user(member.user)

      index = get(member_conn, ~p"/app/#{workspace.slug}/credentials")
      member_conn = recycle(index)
      refute inertia_props(index).canManage
      assert [prop] = inertia_props(index).credentials
      assert prop.id == credential.id
      refute Map.has_key?(prop, :secret)
      assert [listed] = ProviderCredentials.list_credentials(member_scope)
      assert listed.id == credential.id

      create_response =
        member_conn
        |> post(~p"/app/#{workspace.slug}/credentials", %{
          "provider_credential" => valid_provider_credential_attributes()
        })

      validate_response =
        member_conn
        |> post(~p"/app/#{workspace.slug}/credentials/#{credential.id}/validate")

      rotate_response =
        member_conn
        |> post(~p"/app/#{workspace.slug}/credentials/#{credential.id}/rotate", %{
          "provider_credential" => %{"secret" => "sk-member-forbidden-rotation"}
        })

      activate_response =
        member_conn
        |> post(~p"/app/#{workspace.slug}/credentials/#{credential.id}/activate-replacement")

      revoke_response =
        member_conn
        |> delete(~p"/app/#{workspace.slug}/credentials/#{credential.id}")

      for conn_response <- [
            create_response,
            validate_response,
            rotate_response,
            activate_response,
            revoke_response
          ] do
        assert response(conn_response, 403) == "Forbidden"
      end
    end
  end
end
