defmodule SilentRegressionWeb.MonitorSetupControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.MonitorSetupsFixtures

  alias SilentRegression.{MonitorSetups, Monitors, ProviderCredentials}
  alias SilentRegression.ProviderCredentialsFixtures

  setup :register_and_log_in_workspace

  describe "authenticated workspace boundary" do
    test "requires login and a verified workspace membership", %{workspace: workspace} do
      logged_out = get(build_conn(), ~p"/app/#{workspace.slug}/monitors/new")
      assert redirected_to(logged_out) == ~p"/users/log-in"

      outsider = SilentRegression.WorkspacesFixtures.accepted_workspace_fixture()

      unauthorized =
        build_conn()
        |> log_in_user(outsider.user)
        |> get(~p"/app/#{workspace.slug}/monitors/new")

      assert response(unauthorized, 404) == "Not found"
    end

    test "uses the same 404 for malformed and cross-workspace setup IDs", %{
      conn: conn,
      workspace: workspace
    } do
      other_scope = SilentRegression.WorkspacesFixtures.workspace_scope_fixture()
      %{monitor: other_monitor} = setup_fixture(other_scope)

      malformed = get(conn, ~p"/app/#{workspace.slug}/monitors/not-a-uuid/setup")

      missing =
        malformed
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{other_monitor.id}/setup")

      assert response(malformed, 404) == "Not found"
      assert response(missing, 404) == "Not found"
    end
  end

  describe "cold-start flow" do
    test "renders the creation page and returns server validation errors", %{
      conn: conn,
      workspace: workspace
    } do
      page = get(conn, ~p"/app/#{workspace.slug}/monitors/new")
      assert html_response(page, 200)
      assert inertia_component(page) == "Monitors/New"
      assert inertia_props(page).pageTitle == "Create monitor"

      invalid =
        page
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/monitors", %{
          "monitor" => %{"name" => "", "description" => ""}
        })

      assert redirected_to(invalid) == ~p"/app/#{workspace.slug}/monitors/new"

      errors_page =
        invalid
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/new")

      assert inertia_props(errors_page).errors.name == "can't be blank"
    end

    test "persists all steps, resumes, reviews call implications, and completes", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      credential = ProviderCredentialsFixtures.provider_credential_fixture(scope)
      {:ok, credential} = ProviderCredentials.validate_credential(scope, credential.id)

      created =
        post(conn, ~p"/app/#{workspace.slug}/monitors", %{
          "monitor" => %{
            "name" => "Support citation guard",
            "description" => "Fail when a supported answer omits citations"
          }
        })

      [setup] = MonitorSetups.list(scope)
      monitor_id = setup.monitor_id

      assert redirected_to(created) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/connection"

      connection_page =
        created
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/connection")

      assert html_response(connection_page, 200)
      assert inertia_component(connection_page) == "Monitors/Setup"
      assert inertia_props(connection_page).step == "connection"
      assert inertia_props(connection_page).progress.completedCount == 1
      assert [credential_prop] = inertia_props(connection_page).credentials
      assert credential_prop.id == credential.id
      refute Map.has_key?(credential_prop, :secret)

      assert inertia_props(connection_page).generationCapabilities.openai["gpt-5.6-luna"][
               "parameters"
             ] ==
               ["max_output_tokens", "reasoning_effort"]

      connection =
        connection_page
        |> recycle()
        |> patch(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/connection", %{
          "connection" => %{
            "provider_credential_id" => credential.id,
            "provider" => "openai",
            "requested_model" => "gpt-5.6-luna"
          }
        })

      assert redirected_to(connection) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/prompt"

      prompt =
        connection
        |> recycle()
        |> patch(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/prompt", %{
          "prompt" => %{
            "system_prompt" => "Use only the supplied context.",
            "user_prompt_template" => "Question: {{question}}",
            "response_format" => %{"type" => "json_object"},
            "generation_config" => %{
              "max_output_tokens" => "512",
              "reasoning_effort" => "low"
            }
          }
        })

      assert redirected_to(prompt) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/cases"

      resumed =
        prompt
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup")

      assert redirected_to(resumed) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/cases"

      cases =
        resumed
        |> recycle()
        |> patch(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/cases", %{
          "cases" => [
            %{
              "case_key" => "citation-required",
              "name" => "Citation required",
              "status" => "active",
              "input_variables_json" => ~s({"question":"Which plan includes SSO?"}),
              "frozen_context" => "Enterprise includes SSO."
            }
          ]
        })

      assert redirected_to(cases) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/review"

      review =
        cases
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/review")

      assert html_response(review, 200)
      assert inertia_props(review).progress.ready
      assert inertia_props(review).activeCaseCount == 1
      assert inertia_props(review).limits.maxActiveCases == 20
      assert inertia_props(review).setup.systemPrompt == "Use only the supplied context."

      completed =
        review
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/complete")

      assert redirected_to(completed) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/setup/review"

      assert {:ok, setup} = MonitorSetups.get(scope, monitor_id)
      assert setup.status == :completed
      assert [_version] = Monitors.list_versions(scope, monitor_id)
    end

    test "supports versioned JSON case import and explicit save-and-exit", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      %{monitor: monitor} = setup_fixture(scope)
      credential = valid_credential_fixture(scope)

      {:ok, _setup} =
        MonitorSetups.update_connection(scope, monitor.id, %{
          provider_credential_id: credential.id,
          provider: "openai",
          requested_model: "gpt-5.6-luna"
        })

      {:ok, _setup} =
        MonitorSetups.update_prompt(scope, monitor.id, %{
          user_prompt_template: "Question: {{question}}",
          response_format: %{type: "text"},
          generation_config: %{max_output_tokens: 256}
        })

      encoded =
        Jason.encode!(%{
          schema_version: 1,
          cases: [
            %{
              case_key: "supported-answer",
              name: "Supported answer",
              input_variables: %{question: "What is supported?"},
              frozen_context: "This statement is supported.",
              status: "active"
            }
          ]
        })

      imported =
        patch(conn, ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/cases", %{
          "case_import" => encoded
        })

      assert redirected_to(imported) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/review"

      left =
        imported
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/leave", %{
          "step" => "cases"
        })

      assert redirected_to(left) == ~p"/app/#{workspace.slug}/monitors"
      assert Phoenix.Flash.get(left.assigns.flash, :info) =~ "resume"
    end

    test "prevents skipping ahead and preserves server-side errors", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      %{monitor: monitor} = setup_fixture(scope)

      gated = get(conn, ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/cases")

      assert redirected_to(gated) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/connection"

      invalid =
        gated
        |> recycle()
        |> patch(~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/connection", %{
          "connection" => %{
            "provider_credential_id" => Ecto.UUID.generate(),
            "provider" => "openai",
            "requested_model" => "gpt-5.6-luna"
          }
        })

      assert redirected_to(invalid) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/connection"

      errors_page =
        invalid
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup/connection")

      assert inertia_props(errors_page).errors.providerCredentialId == "is not available"
    end
  end

  test "filters prompt, context, variables, import, and output parameters from logs" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "prompt" => %{
          "system_prompt" => "sensitive-system",
          "user_prompt_template" => "sensitive-user"
        },
        "cases" => [
          %{
            "frozen_context" => "sensitive-context",
            "input_variables_json" => "sensitive-variables"
          }
        ],
        "case_import" => "sensitive-import",
        "output" => "sensitive-output"
      })

    inspected = inspect(filtered)
    refute inspected =~ "sensitive-system"
    refute inspected =~ "sensitive-user"
    refute inspected =~ "sensitive-context"
    refute inspected =~ "sensitive-variables"
    refute inspected =~ "sensitive-import"
    refute inspected =~ "sensitive-output"
  end
end
