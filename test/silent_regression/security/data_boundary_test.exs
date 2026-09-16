defmodule SilentRegression.Security.DataBoundaryTest do
  use SilentRegression.DataCase, async: false

  import SilentRegression.ProviderCredentialsFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Audit
  alias SilentRegression.Captures.Workers.ObservationWorker
  alias SilentRegression.Notifications.Workers.AlertEmailWorker
  alias SilentRegression.ProductAnalytics
  alias SilentRegression.ProviderCredentials.KeyRotation

  @sensitive_key_fragments ~w(
    prompt context output secret password api_key authorization email rationale
  )

  test "audit actions and metadata are strictly allowlisted" do
    scope = workspace_scope_fixture()

    assert {:ok, event} =
             Audit.record_event(%{
               action: "monitor.created",
               target_type: "monitor",
               target_id: Ecto.UUID.generate(),
               workspace_id: scope.workspace.id,
               actor_user_id: scope.user.id,
               metadata: %{}
             })

    assert event.metadata == %{}

    assert {:error, :action_or_metadata_not_allowlisted} =
             Audit.record_event(%{
               action: "monitor.created",
               target_type: "monitor",
               target_id: Ecto.UUID.generate(),
               workspace_id: scope.workspace.id,
               actor_user_id: scope.user.id,
               metadata: %{"prompt" => "customer content"}
             })

    assert_raise ArgumentError, ~r/invalid audit event/, fn ->
      Audit.record_event!(%{
        action: "unregistered.action",
        target_type: "monitor",
        metadata: %{}
      })
    end

    refute Audit.metadata_allowlists()
           |> Map.values()
           |> List.flatten()
           |> Enum.any?(&sensitive_key?/1)
  end

  test "product analytics rejects customer content and arbitrary properties" do
    scope = workspace_scope_fixture()

    assert_raise ArgumentError, ~r/invalid product event or properties/, fn ->
      ProductAnalytics.record!(
        scope,
        "monitor_setup.left",
        Ecto.UUID.generate(),
        %{"step" => "prompt", "output" => "customer content"}
      )
    end
  end

  test "credential key inventory exposes tags and counts but never plaintext" do
    scope = workspace_scope_fixture()
    plaintext = "sk-sensitive-key-rotation-sentinel"
    _credential = provider_credential_fixture(scope, %{secret: plaintext})

    inventory = KeyRotation.inventory()

    assert inventory.active_tag == "AES.GCM.V1"
    assert inventory.total_count == 1
    assert inventory.decryptable_count == 1
    assert inventory.unreadable_count == 0
    assert inventory.tag_counts == %{"AES.GCM.V1" => 1}
    refute inspect(inventory) =~ plaintext
  end

  test "Phoenix parameter filtering covers every customer-content boundary" do
    keys =
      ~w(
        password secret api_key authorization system_prompt user_prompt_template frozen_context
        input_variables input_variables_json case_import output output_text contract root rules
        alternatives fact_alternatives source_ids allowed_values
      )

    params = Map.new(keys, &{&1, "sensitive-sentinel"})

    assert params
           |> Phoenix.Logger.filter_values()
           |> Map.values()
           |> Enum.all?(&(&1 == "[FILTERED]"))
  end

  test "telemetry tags and Oban arguments are content-free allowlists" do
    assert SilentRegressionWeb.Telemetry.metrics()
           |> Enum.flat_map(&Map.get(&1, :tags, []))
           |> Enum.uniq()
           |> Enum.all?(&(&1 in [:route, :event]))

    capture_args =
      ObservationWorker.new(%{
        capture_run_id: Ecto.UUID.generate(),
        observation_id: Ecto.UUID.generate()
      })
      |> Ecto.Changeset.get_field(:args)

    email_args =
      AlertEmailWorker.new(%{delivery_id: Ecto.UUID.generate()})
      |> Ecto.Changeset.get_field(:args)

    assert Map.keys(capture_args) |> Enum.sort() == [:capture_run_id, :observation_id]
    assert Map.keys(email_args) == [:delivery_id]
  end

  defp sensitive_key?(key) do
    Enum.any?(@sensitive_key_fragments, &String.contains?(key, &1))
  end
end
