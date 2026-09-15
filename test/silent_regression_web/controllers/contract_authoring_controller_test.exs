defmodule SilentRegressionWeb.ContractAuthoringControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  import Inertia.Testing
  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.MonitorSetupsFixtures

  alias SilentRegression.ContractAuthoring.Templates

  setup :register_and_log_in_workspace

  describe "authenticated workspace boundary" do
    test "requires login and returns the same 404 for malformed and cross-workspace IDs", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      completed = complete_setup_fixture(scope)

      logged_out =
        get(
          build_conn(),
          ~p"/app/#{workspace.slug}/monitors/#{completed.monitor.id}/contract"
        )

      assert redirected_to(logged_out) == ~p"/users/log-in"

      other_scope = SilentRegression.WorkspacesFixtures.workspace_scope_fixture()
      other = complete_setup_fixture(other_scope)

      malformed = get(conn, ~p"/app/#{workspace.slug}/monitors/not-a-uuid/contract")

      cross_workspace =
        malformed
        |> recycle()
        |> get(~p"/app/#{workspace.slug}/monitors/#{other.monitor.id}/contract")

      assert response(malformed, 404) == "Not found"
      assert response(cross_workspace, 404) == "Not found"
    end

    test "redirects an incomplete monitor to its setup", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      %{monitor: monitor} = setup_fixture(scope)

      response = get(conn, ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/contract")

      assert redirected_to(response) ==
               ~p"/app/#{workspace.slug}/monitors/#{monitor.id}/setup"
    end
  end

  describe "contract authoring and approval" do
    test "renders templates and returns server-side draft validation errors", %{
      conn: conn,
      scope: scope,
      workspace: workspace
    } do
      completed = complete_setup_fixture(scope)
      path = ~p"/app/#{workspace.slug}/monitors/#{completed.monitor.id}/contract"

      page = get(conn, path)

      assert html_response(page, 200)
      assert inertia_component(page) == "Monitors/Contract"
      assert inertia_props(page).contract == nil
      assert length(inertia_props(page).templates) == 4
      assert Jason.decode!(hd(inertia_props(page).templates).rootJson)["rules"]
      assert inertia_props(page).canApprove

      invalid =
        page
        |> recycle()
        |> put(path, %{
          "contract" => %{
            "template_key" => "classification",
            "assistance_mode" => "self_serve",
            "root" => %{"id" => "contract", "type" => "all", "rules" => []}
          }
        })

      assert redirected_to(invalid) == path

      errors_page = invalid |> recycle() |> get(path)
      assert inertia_props(errors_page).errors.rules =~ "valid flat rule list"
    end

    test "evaluates fixtures locally, exposes contradictions, and seals owner approval", %{
      conn: conn,
      scope: scope,
      user: user,
      workspace: workspace
    } do
      completed = complete_setup_fixture(scope)
      monitor_id = completed.monitor.id
      path = ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/contract"
      {:ok, template} = Templates.fetch("classification")

      saved =
        put(conn, path, %{
          "contract" => %{
            "template_key" => "classification",
            "assistance_mode" => "founder_assisted",
            "root" => template["root"]
          }
        })

      assert redirected_to(saved) == path

      valid =
        saved
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/contract/fixtures", %{
          "fixture" => %{
            "name" => "Known valid",
            "output_text" => "approved",
            "expected_status" => "pass",
            "expected_failed_rule_ids" => []
          }
        })

      contradicted =
        valid
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/contract/fixtures", %{
          "fixture" => %{
            "name" => "Known invalid",
            "output_text" => "approved",
            "expected_status" => "fail",
            "expected_failed_rule_ids" => ["allowed_label"]
          }
        })

      contradiction_page = contradicted |> recycle() |> get(path)
      assert [first, second] = inertia_props(contradiction_page).fixtures
      assert first.matches
      refute second.matches
      assert second.actual.status == :pass

      assert Jason.decode!(second.expectedRuleStatusesJson)["allowed_label"] == "fail"

      assert Enum.any?(inertia_props(contradiction_page).readiness.blockers, fn blocker ->
               blocker.code == "fixture_mismatch"
             end)

      corrected =
        contradiction_page
        |> recycle()
        |> patch(
          ~p"/app/#{workspace.slug}/monitors/#{monitor_id}/contract/fixtures/#{second.id}",
          %{
            "fixture" => %{
              "name" => "Known invalid",
              "output_text" => "maybe",
              "expected_status" => "fail",
              "expected_failed_rule_ids" => ["allowed_label"]
            }
          }
        )

      ready_page = corrected |> recycle() |> get(path)
      assert inertia_props(ready_page).readiness.ready

      approved =
        ready_page
        |> recycle()
        |> post(~p"/app/#{workspace.slug}/monitors/#{monitor_id}/contract/approve")

      sealed_page = approved |> recycle() |> get(path)
      assert inertia_props(sealed_page).contract.status == :approved
      assert inertia_props(sealed_page).contract.approvedByUserId == user.id
      assert inertia_props(sealed_page).contract.fingerprint =~ ~r/^[0-9a-f]{64}$/

      assert %{"rules" => [%{"allowed_values" => _values} | _rest]} =
               Jason.decode!(inertia_props(sealed_page).contract.rootJson)
    end

    test "members can author but receive an owner-only approval response", %{
      scope: owner_scope,
      workspace: workspace
    } do
      completed = complete_setup_fixture(owner_scope)
      member = SilentRegression.WorkspacesFixtures.invite_and_accept_member(owner_scope)

      member_scope =
        SilentRegression.Accounts.Scope.for_workspace(
          member.user,
          workspace,
          member.membership
        )

      _draft = draft_fixture(member_scope, completed.monitor)
      _valid = fixture(member_scope, completed.monitor)

      _invalid =
        fixture(member_scope, completed.monitor, %{
          name: "Known invalid",
          output_text: "maybe",
          expected_status: "fail",
          expected_failed_rule_ids: ["allowed_label"]
        })

      member_conn = log_in_user(build_conn(), member.user)
      path = ~p"/app/#{workspace.slug}/monitors/#{completed.monitor.id}/contract"

      page = get(member_conn, path)
      refute inertia_props(page).canApprove

      response = post(recycle(page), path <> "/approve")
      assert redirected_to(response) == path
      assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Only a workspace owner"
    end
  end

  test "filters contract rules and fixture output parameters from logs" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "contract" => %{"root" => %{"rules" => ["sensitive-rule"]}},
        "fixture" => %{"output_text" => "sensitive-output"}
      })

    inspected = inspect(filtered)
    refute inspected =~ "sensitive-rule"
    refute inspected =~ "sensitive-output"
  end
end
