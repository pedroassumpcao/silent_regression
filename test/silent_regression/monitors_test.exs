defmodule SilentRegression.MonitorsTest do
  use SilentRegression.DataCase, async: true

  alias SilentRegression.{Audit, Monitors, Repo}
  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Monitors.CaseVersion
  alias SilentRegression.{MonitorsFixtures, WorkspacesFixtures}

  setup do
    scope = WorkspacesFixtures.workspace_scope_fixture()
    other_scope = WorkspacesFixtures.workspace_scope_fixture()
    %{scope: scope, other_scope: other_scope}
  end

  describe "workspace-scoped monitor identity" do
    test "creates, lists, fetches, and edits metadata without changing behavior", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      version = MonitorsFixtures.version_fixture(scope, monitor)

      assert [listed] = Monitors.list_monitors(scope)
      assert listed.id == monitor.id
      assert {:ok, fetched} = Monitors.get_monitor(scope, monitor.id)
      assert fetched.id == monitor.id

      assert {:ok, updated} =
               Monitors.update_monitor_metadata(scope, monitor.id, %{
                 name: "Renamed monitor",
                 description: "Clarified purpose"
               })

      assert updated.name == "Renamed monitor"
      assert {:ok, persisted_version} = Monitors.get_version(scope, version.id)
      assert persisted_version.fingerprint == version.fingerprint

      actions = scope |> Audit.list_workspace_events() |> Enum.map(& &1.action)
      assert "monitor.created" in actions
      assert "monitor.metadata_updated" in actions
    end

    test "members may collaborate on monitor configuration", %{scope: owner_scope} do
      accepted = WorkspacesFixtures.invite_and_accept_member(owner_scope)

      member_scope =
        Scope.for_workspace(accepted.user, accepted.workspace, accepted.membership)

      assert {:ok, monitor} = Monitors.create_monitor(member_scope, %{name: "Member monitor"})
      assert {:ok, version} = Monitors.create_version(member_scope, monitor.id, valid_version())
      assert version.monitor_id == monitor.id
    end

    test "never exposes or mutates records in another workspace", %{
      scope: scope,
      other_scope: other_scope
    } do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      version = MonitorsFixtures.version_fixture(scope, monitor)

      assert [] = Monitors.list_monitors(other_scope)
      assert {:error, :not_found} = Monitors.get_monitor(other_scope, monitor.id)
      assert {:error, :not_found} = Monitors.list_versions(other_scope, monitor.id)
      assert {:error, :not_found} = Monitors.get_version(other_scope, version.id)

      assert {:error, :not_found} =
               Monitors.update_monitor_metadata(other_scope, monitor.id, %{name: "Intrusion"})

      assert {:error, :not_found} =
               Monitors.create_version(other_scope, monitor.id, valid_version())

      assert {:error, :not_found} =
               Monitors.activate_version(other_scope, monitor.id, version.id)

      assert {:error, :not_found} =
               Monitors.transition_monitor(other_scope, monitor.id, :archived)
    end
  end

  describe "immutable versions" do
    test "creates monotonic candidates and supersedes the replaced draft", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      first = MonitorsFixtures.version_fixture(scope, monitor)

      assert {:error, :unchanged_configuration} =
               Monitors.create_version(scope, monitor.id, valid_version())

      assert {:ok, still_first} = Monitors.get_version(scope, first.id)
      assert still_first.status == :draft

      assert {:ok, second} =
               Monitors.create_version(
                 scope,
                 monitor.id,
                 valid_version(%{system_prompt: "A revised prompt"})
               )

      assert second.version == 2
      assert second.predecessor_id == first.id
      assert {:ok, superseded} = Monitors.get_version(scope, first.id)
      assert superseded.status == :superseded

      assert {:ok, current} = Monitors.get_monitor(scope, monitor.id)
      assert current.draft_version_id == second.id
    end

    test "allows metadata-only case successors without changing compatibility", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      first = MonitorsFixtures.version_fixture(scope, monitor)
      attributes = valid_version()
      [case_attributes] = attributes.cases

      assert {:ok, second} =
               Monitors.create_version(scope, monitor.id, %{
                 attributes
                 | cases: [%{case_attributes | name: "Renamed case", position: 12}]
               })

      assert first.fingerprint == second.fingerprint
      assert :ok = Monitors.ensure_compatible_versions(scope, first.id, second.id)
    end

    test "database rejects monitor-version behavior updates", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      version = MonitorsFixtures.version_fixture(scope, monitor)

      assert_raise Postgrex.Error, ~r/monitor version content is immutable/, fn ->
        version
        |> Ecto.Changeset.change(system_prompt: "mutated")
        |> Repo.update!()
      end
    end

    test "database rejects case content updates", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      version = MonitorsFixtures.version_fixture(scope, monitor)
      [case_version] = version.cases

      assert_raise Postgrex.Error, ~r/case version content is immutable/, fn ->
        case_version
        |> Ecto.Changeset.change(name: "mutated")
        |> Repo.update!()
      end
    end
  end

  describe "activation and monitor lifecycle" do
    test "activates new configurations and preserves the prior version", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      first = MonitorsFixtures.version_fixture(scope, monitor)
      assert {:ok, monitor} = Monitors.activate_version(scope, monitor.id, first.id)

      assert monitor.state == :validating
      assert monitor.active_version_id == first.id
      assert monitor.draft_version_id == nil

      assert {:ok, second} =
               Monitors.create_version(
                 scope,
                 monitor.id,
                 valid_version(%{user_prompt_template: "Revised: {{question}}"})
               )

      assert {:ok, monitor} = Monitors.activate_version(scope, monitor.id, second.id)
      assert monitor.active_version_id == second.id

      assert {:ok, first} = Monitors.get_version(scope, first.id)
      assert first.status == :superseded
      assert first.superseded_at

      assert {:ok, second} = Monitors.get_version(scope, second.id)
      assert second.status == :active
      assert second.activated_at
    end

    test "enforces the lifecycle and audits activation, pause, resume, and archive", %{
      scope: scope
    } do
      monitor = MonitorsFixtures.monitor_fixture(scope)

      assert {:error, :active_configuration_required} =
               Monitors.transition_monitor(scope, monitor.id, :active)

      version = MonitorsFixtures.version_fixture(scope, monitor)
      assert {:ok, monitor} = Monitors.activate_version(scope, monitor.id, version.id)

      assert {:error, invalid_transition} =
               Monitors.transition_monitor(scope, monitor.id, :active)

      refute invalid_transition.valid?

      assert {:ok, monitor} = Monitors.transition_monitor(scope, monitor.id, :ready)
      assert {:ok, monitor} = Monitors.transition_monitor(scope, monitor.id, :baseline_pending)
      assert {:ok, monitor} = Monitors.transition_monitor(scope, monitor.id, :active)
      assert {:ok, monitor} = Monitors.transition_monitor(scope, monitor.id, :paused)
      assert {:ok, monitor} = Monitors.transition_monitor(scope, monitor.id, :active)
      assert {:ok, archived} = Monitors.transition_monitor(scope, monitor.id, :archived)

      assert archived.state == :archived
      assert archived.archived_at
      assert {:error, :archived} = Monitors.create_version(scope, monitor.id, valid_version())

      actions = scope |> Audit.list_workspace_events() |> Enum.map(& &1.action)
      assert "monitor_version.activated" in actions
      assert "monitor.paused" in actions
      assert "monitor.resumed" in actions
      assert "monitor.archived" in actions
    end
  end

  describe "compatibility" do
    test "accepts exact provenance and explains incompatible versions", %{scope: scope} do
      monitor = MonitorsFixtures.monitor_fixture(scope)
      first = MonitorsFixtures.version_fixture(scope, monitor)
      assert :ok = Monitors.ensure_compatible_versions(scope, first.id, first.id)

      assert {:ok, second} =
               Monitors.create_version(
                 scope,
                 monitor.id,
                 valid_version(%{generation_config: %{max_output_tokens: 512}})
               )

      assert {:error, %{reason: :incompatible_provenance, mismatches: mismatches}} =
               Monitors.ensure_compatible_versions(scope, first.id, second.id)

      assert :monitor_version_fingerprint in mismatches
    end

    test "imported and manually entered cases persist with the same identity", %{scope: scope} do
      manual_monitor = MonitorsFixtures.monitor_fixture(scope)
      imported_monitor = MonitorsFixtures.monitor_fixture(scope)
      attributes = valid_version()

      encoded = Jason.encode!(%{schema_version: 1, cases: attributes.cases})
      assert {:ok, imported_cases} = SilentRegression.Monitors.CaseImport.parse(encoded)

      manual_version = MonitorsFixtures.version_fixture(scope, manual_monitor)

      imported_version =
        MonitorsFixtures.version_fixture(scope, imported_monitor, %{cases: imported_cases})

      assert manual_version.fingerprint == imported_version.fingerprint

      assert Enum.map(manual_version.cases, &case_identity/1) ==
               Enum.map(imported_version.cases, &case_identity/1)
    end
  end

  defp valid_version(overrides \\ %{}) do
    MonitorsFixtures.valid_version_attributes(overrides)
  end

  defp case_identity(%CaseVersion{} = case_version) do
    Map.take(case_version, [
      :case_key,
      :name,
      :position,
      :status,
      :input_variables,
      :frozen_context,
      :fingerprint
    ])
  end
end
