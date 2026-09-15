defmodule SilentRegression.ContractAuthoringTest do
  use SilentRegression.DataCase, async: true

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit
  alias SilentRegression.ContractAuthoring
  alias SilentRegression.ContractAuthoring.{ContractFixture, ContractVersion, Templates}
  alias SilentRegression.Contracts
  alias SilentRegression.Repo

  setup do
    scope = workspace_scope_fixture()
    completed = contract_ready_monitor_fixture(scope)
    %{scope: scope, completed: completed, monitor: completed.monitor}
  end

  describe "templates and draft provenance" do
    test "ships four valid workflow templates and records accepted, edited, removed, and added rules",
         %{scope: scope, monitor: monitor} do
      assert Enum.map(Templates.all(), & &1["key"]) == [
               "structured_json",
               "classification",
               "grounded_answer",
               "required_text"
             ]

      for template <- Templates.all() do
        assert {:ok, _contract} =
                 Contracts.parse_contract(%{
                   "schema_version" => 1,
                   "contract_id" => Ecto.UUID.generate(),
                   "contract_version" => 1,
                   "monitor_id" => monitor.id,
                   "root" => template["root"]
                 })
      end

      {:ok, template} = Templates.fetch("classification")

      edited_root = %{
        template["root"]
        | "rules" => [
            %{
              "id" => "allowed_label",
              "type" => "classification",
              "allowed_values" => ["allow", "deny"]
            },
            %{
              "id" => "required_disclosure",
              "type" => "required_text",
              "alternatives" => ["reviewed"]
            }
          ]
      }

      assert {:ok, draft} =
               ContractAuthoring.save_draft(scope, monitor.id, %{
                 template_key: "classification",
                 assistance_mode: "founder_assisted",
                 root: edited_root
               })

      assert draft.assistance_mode == :founder_assisted

      assert draft.template_usage["rules"] == [
               %{
                 "action" => "edited",
                 "rule_id" => "allowed_label",
                 "rule_type" => "classification",
                 "suggestion_id" => "allowed_label"
               },
               %{
                 "action" => "removed",
                 "rule_id" => nil,
                 "rule_type" => "length",
                 "suggestion_id" => "label_length"
               },
               %{
                 "action" => "added",
                 "rule_id" => "required_disclosure",
                 "rule_type" => "required_text",
                 "suggestion_id" => nil
               }
             ]

      assert draft.contract_fingerprint =~ ~r/^[0-9a-f]{64}$/
      assert draft.fixture_set_fingerprint =~ ~r/^[0-9a-f]{64}$/
      assert draft.fingerprint =~ ~r/^[0-9a-f]{64}$/

      [event] =
        scope
        |> Audit.list_workspace_events()
        |> Enum.filter(&(&1.action == "contract_version.created"))

      assert event.metadata["assistance_mode"] == "founder_assisted"
      refute inspect(event.metadata) =~ "reviewed"
    end

    test "rejects nested authoring trees, malformed rules, and cross-workspace access", %{
      scope: scope,
      monitor: monitor
    } do
      nested = %{
        "id" => "contract",
        "type" => "all",
        "rules" => [
          %{
            "id" => "nested",
            "type" => "any",
            "rules" => [%{"id" => "valid", "type" => "json_valid"}]
          }
        ]
      }

      assert {:error, changeset} =
               ContractAuthoring.save_draft(scope, monitor.id, %{
                 template_key: "structured_json",
                 assistance_mode: "self_serve",
                 root: nested
               })

      assert "must contain a valid flat rule list" in errors_on(changeset).rules

      other_scope = workspace_scope_fixture()
      assert {:error, :not_found} = ContractAuthoring.get_state(scope, monitor.id <> "x")
      assert {:error, :not_found} = ContractAuthoring.get_state(other_scope, monitor.id)
    end
  end

  describe "fixture validation and approval" do
    test "shows contradictions, requires both fixture kinds, and seals only exact agreement", %{
      scope: scope,
      monitor: monitor
    } do
      draft = draft_fixture(scope, monitor)
      original_fingerprint = draft.fingerprint

      valid_fixture = fixture(scope, monitor)

      assert {:ok, contradicted_fixture} =
               ContractAuthoring.add_fixture(scope, monitor.id, %{
                 name: "Expected rejection",
                 output_text: "approved",
                 expected_status: "fail",
                 expected_failed_rule_ids: ["allowed_label"]
               })

      assert {:ok, state} = ContractAuthoring.get_state(scope, monitor.id)
      refute state.readiness.ready?
      assert Enum.any?(state.readiness.blockers, &(&1.code == "fixture_mismatch"))

      contradicted = Enum.find(state.fixture_results, &(&1.fixture.id == contradicted_fixture.id))
      refute contradicted.matches?
      assert contradicted.actual_rule_statuses["allowed_label"] == "pass"
      assert contradicted.fixture.expected_rule_statuses["allowed_label"] == "fail"

      assert {:error, {:approval_blocked, blockers}} =
               ContractAuthoring.approve(scope, monitor.id)

      assert Enum.any?(blockers, &(&1.code == "fixture_mismatch"))

      assert {:ok, corrected} =
               ContractAuthoring.update_fixture(
                 scope,
                 monitor.id,
                 contradicted_fixture.id,
                 %{
                   name: "Known-invalid output",
                   output_text: "maybe",
                   expected_status: "fail",
                   expected_failed_rule_ids: ["allowed_label"]
                 }
               )

      assert corrected.fingerprint != contradicted_fixture.fingerprint

      assert {:ok, ready_state} = ContractAuthoring.get_state(scope, monitor.id)
      assert ready_state.readiness.ready?
      assert Enum.all?(ready_state.fixture_results, & &1.matches?)
      assert ready_state.contract_version.fingerprint != original_fingerprint

      assert {:ok, approved} = ContractAuthoring.approve(scope, monitor.id)
      assert approved.status == :approved
      assert approved.approved_by_user_id == scope.user.id
      assert approved.approved_at

      assert approved.fixtures |> Enum.map(& &1.id) |> Enum.sort() ==
               [valid_fixture.id, corrected.id] |> Enum.sort()
    end

    test "clears fixture judgments when draft rules change", %{scope: scope, monitor: monitor} do
      _draft = draft_fixture(scope, monitor)
      fixture = fixture(scope, monitor)

      {:ok, template} = Templates.fetch("classification")

      changed_root =
        put_in(
          template,
          ["root", "rules", Access.at(0), "allowed_values"],
          ["approved", "rejected", "review"]
        )["root"]

      assert {:ok, _draft} =
               ContractAuthoring.save_draft(scope, monitor.id, %{
                 template_key: "classification",
                 assistance_mode: "self_serve",
                 root: changed_root
               })

      reloaded = Repo.get!(ContractFixture, fixture.id)
      assert reloaded.expected_rule_statuses == %{}

      assert {:ok, state} = ContractAuthoring.get_state(scope, monitor.id)
      refute state.readiness.ready?
      assert Enum.any?(state.readiness.blockers, &(&1.code == "fixture_judgment_required"))
    end

    test "members may author and validate but only owners may approve", %{
      scope: owner_scope,
      monitor: monitor,
      completed: completed
    } do
      member = invite_and_accept_member(owner_scope)

      member_scope =
        Scope.for_workspace(member.user, owner_scope.workspace, member.membership)

      _draft = draft_fixture(member_scope, monitor)
      _valid = fixture(member_scope, monitor)

      _invalid =
        fixture(member_scope, monitor, %{
          name: "Known-invalid output",
          output_text: "maybe",
          expected_status: "fail",
          expected_failed_rule_ids: ["allowed_label"]
        })

      assert {:error, :owner_required} = ContractAuthoring.approve(member_scope, monitor.id)
      assert {:ok, approved} = ContractAuthoring.approve(owner_scope, monitor.id)
      assert approved.monitor_version_id == completed.version.id
    end
  end

  describe "approved history" do
    test "creates a successor draft with copied fixtures instead of editing approval", %{
      scope: scope,
      monitor: monitor
    } do
      _draft = draft_fixture(scope, monitor)
      _valid = fixture(scope, monitor)

      _invalid =
        fixture(scope, monitor, %{
          name: "Known-invalid output",
          output_text: "maybe",
          expected_status: "fail",
          expected_failed_rule_ids: ["allowed_label"]
        })

      {:ok, approved} = ContractAuthoring.approve(scope, monitor.id)
      assert {:ok, revision} = ContractAuthoring.create_revision(scope, monitor.id)

      assert revision.status == :draft
      assert revision.version == approved.version + 1
      assert revision.predecessor_id == approved.id
      assert revision.root == approved.root
      assert revision.fingerprint == approved.fingerprint
      assert length(revision.fixtures) == 2

      reloaded_approved = Repo.get!(ContractVersion, approved.id)
      assert reloaded_approved.status == :approved
      assert reloaded_approved.root == approved.root
    end

    test "database guards approved contract and fixture content", %{
      scope: scope,
      monitor: monitor
    } do
      _draft = draft_fixture(scope, monitor)
      _valid = fixture(scope, monitor)

      _invalid =
        fixture(scope, monitor, %{
          name: "Known-invalid output",
          output_text: "maybe",
          expected_status: "fail",
          expected_failed_rule_ids: ["allowed_label"]
        })

      {:ok, approved} = ContractAuthoring.approve(scope, monitor.id)
      [fixture | _rest] = approved.fixtures

      assert_raise Postgrex.Error, ~r/approved contract version content is immutable/, fn ->
        approved
        |> Ecto.Changeset.change(root: %{"id" => "changed"})
        |> Repo.update!()
      end

      assert_raise Postgrex.Error, ~r/approved contract fixtures are immutable/, fn ->
        fixture
        |> Ecto.Changeset.change(output_text: "changed")
        |> Repo.update!()
      end
    end
  end
end
