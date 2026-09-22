defmodule SilentRegression.GuidedSetupsTest do
  use SilentRegression.DataCase, async: true
  import SilentRegression.GuidedSetupsFixtures
  alias SilentRegression.{Audit, ContractAuthoring, GuidedSetups, Repo, WorkspacesFixtures}
  alias SilentRegression.GuidedSetups.{Draft, Routing}
  alias SilentRegression.Monitors.Monitor

  setup do
    %{scope: WorkspacesFixtures.workspace_scope_fixture()}
  end

  test "saves incomplete native JSON and lists without making a monitor; rejects stale tabs", %{
    scope: scope
  } do
    {:ok, draft} = GuidedSetups.create(scope)

    raw = %{
      draft.raw
      | "nativeJson" => "{unfinished",
        "mode" => "native",
        "labelsText" => "first\n",
        "messages" => []
    }

    assert {:ok, saved} = GuidedSetups.save(scope, draft.id, draft.revision, raw)
    assert {:ok, resumed} = GuidedSetups.get(scope, draft.id)
    assert resumed.raw == raw
    assert GuidedSetups.state(scope, resumed).stage == :request
    assert {:error, :stale_draft} = GuidedSetups.save(scope, draft.id, draft.revision, draft.raw)
    assert Repo.aggregate(Monitor, :count) == 0

    assert {:error, :invalid_draft} =
             GuidedSetups.save(scope, draft.id, saved.revision, Map.put(raw, "approved", true))

    assert {:error, :invalid_draft} =
             GuidedSetups.save(
               scope,
               draft.id,
               saved.revision,
               Map.put(raw, "instruction", String.duplicate("x", 65_537))
             )
  end

  test "scope checks prevent cross-workspace read, save, proof review and sealing", %{
    scope: scope
  } do
    draft = draft_fixture(scope)
    other = WorkspacesFixtures.workspace_scope_fixture()
    assert {:error, :not_found} = GuidedSetups.get(other, draft.id)
    assert {:error, :not_found} = GuidedSetups.save(other, draft.id, draft.revision, draft.raw)

    assert {:error, :not_found} =
             GuidedSetups.review(other, draft.id, draft.revision, judgments(draft))

    assert {:error, :not_found} = GuidedSetups.seal(other, draft.id, draft.revision)
    assert {:error, :not_found} = GuidedSetups.state(other, draft)
  end

  test "proof uses both production engines and binds human review to the exact input, request and output",
       %{scope: scope} do
    draft = draft_fixture(scope)
    state = GuidedSetups.state(scope, draft)
    assert state.stage == :checks
    assert state.variables == ["action"]
    wrong = Enum.find(state.proof, &(&1.case_key == "allow-case" and &1.output == "rejected"))
    assert wrong.shared == "pass"
    assert wrong.specific == "fail"
    refute state.reviewed
    assert {:error, :draft_incomplete} = GuidedSetups.seal(scope, draft.id, draft.revision)

    assert {:error, :proof_review_required} =
             GuidedSetups.review(scope, draft.id, draft.revision, [%{"fingerprint" => "stale"}])

    assert {:error, :proof_review_required} =
             GuidedSetups.review(scope, draft.id, draft.revision, [
               %{"fingerprint" => wrong.fingerprint, "shared" => "pass", "specific" => "pass"}
             ])

    assert {:ok, reviewed} =
             GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))

    assert GuidedSetups.state(scope, reviewed).stage == :review
    assert reviewed.reviews[wrong.fingerprint]["actor_user_id"] == scope.user.id
    raw = put_in(reviewed.raw, ["messages", Access.at(0), "content"], "action={{action}}")
    assert {:ok, edited} = GuidedSetups.save(scope, draft.id, reviewed.revision, raw)
    assert edited.reviews == %{}

    assert {:error, :proof_review_required} =
             GuidedSetups.review(scope, draft.id, edited.revision, judgments(draft))

    assert {:error, :stale_draft} = GuidedSetups.seal(scope, draft.id, reviewed.revision)
  end

  test "atomically seals once into existing immutable configuration and unapproved contract; no capture",
       %{scope: scope} do
    draft = reviewed_fixture(scope)
    assert {:ok, sealed} = GuidedSetups.seal(scope, draft.id, draft.revision)
    assert sealed.monitor_id
    assert sealed.sealed_at
    assert {:ok, duplicate} = GuidedSetups.seal(scope, draft.id, draft.revision)
    assert duplicate.monitor_id == sealed.monitor_id
    assert Repo.aggregate(Monitor, :count) == 1
    assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
    assert {:ok, state} = ContractAuthoring.get_state(scope, sealed.monitor_id)
    assert state.contract_version.status == :draft
    assert state.readiness.ready?
    assert length(state.fixtures) == 3
    assert state.monitor_version.request_mode == :provider_native_v1

    assert Enum.all?(
             Repo.preload(state.monitor_version, :cases).cases,
             &(&1.expectation_schema_version == "case_expectation_v1")
           )

    assert {:error, :already_sealed} =
             GuidedSetups.save(scope, draft.id, sealed.revision, draft.raw)

    assert {:error, :already_sealed} =
             GuidedSetups.review(scope, draft.id, sealed.revision, judgments(draft))

    refute inspect(Audit.list_workspace_events(scope)) =~ draft.raw["instruction"]
    assert GuidedSetups.list(scope) == []

    assert_raise Postgrex.Error, fn ->
      sealed
      |> Ecto.Changeset.change(raw: %{sealed.raw | "name" => "Rewrite history"})
      |> Repo.update!()
    end
  end

  test "failed credential recheck rolls back sealing and preserves all draft data", %{
    scope: scope
  } do
    draft = reviewed_fixture(scope)
    SilentRegression.ProviderCredentials.revoke_credential(scope, draft.raw["credentialId"])
    assert {:error, :draft_incomplete} = GuidedSetups.seal(scope, draft.id, draft.revision)
    assert Repo.aggregate(Monitor, :count) == 0
    assert Repo.get!(Draft, draft.id).reviews == draft.reviews
  end

  test "members can author and seal but cannot approve checks or grant owner rights", %{
    scope: scope
  } do
    accepted = WorkspacesFixtures.invite_and_accept_member(scope)

    member =
      SilentRegression.Accounts.Scope.for_workspace(
        accepted.user,
        scope.workspace,
        accepted.membership
      )

    draft = reviewed_fixture(scope)
    assert {:ok, sealed} = GuidedSetups.seal(member, draft.id, draft.revision)
    assert {:error, :owner_required} = ContractAuthoring.approve(member, sealed.monitor_id)
  end

  test "typed and native OpenAI requests agree; native malformed JSON remains authorable", %{
    scope: scope
  } do
    raw = raw_fixture(scope)
    assert {:ok, typed} = Routing.compile(raw)

    native = %{
      raw
      | "mode" => "native",
        "nativeJson" => Jason.encode!(typed.attributes.request_template)
    }

    assert {:ok, compiled} = Routing.compile(native)
    assert typed.requests == compiled.requests
    invalid = %{native | "nativeJson" => "{"}
    assert :ok = Routing.validate_raw(invalid)
    assert {:error, {:request, _}} = Routing.compile(invalid)
  end

  test "Anthropic ordered/native requests preserve source variables and enforce provider constraints",
       %{scope: scope} do
    raw = raw_fixture(scope)
    raw = %{raw | "provider" => "anthropic", "model" => "claude-haiku-4-5-20251001"}
    assert {:ok, typed} = Routing.compile(raw)
    assert hd(typed.requests).artifact_json =~ "api.anthropic.com"

    native = %{
      raw
      | "mode" => "native",
        "nativeJson" => Jason.encode!(typed.attributes.request_template)
    }

    assert {:ok, compiled} = Routing.compile(native)
    assert typed.requests == compiled.requests
    invalid = %{raw | "messages" => [%{"role" => "assistant", "content" => "Wrong start"}]}
    assert {:error, {:request, _}} = Routing.compile(invalid)
  end

  test "normalization collisions and punctuation-only labels are blocked before proposing proof",
       %{scope: scope} do
    raw = raw_fixture(scope)

    for labels <- ["approved\nAPPROVED", "!!!\n???", "approved\n", "approved"] do
      assert {:error, {:examples, _}} = Routing.compile(%{raw | "labelsText" => labels})
    end
  end

  test "partial judgments retain exact synthetic output; changing a case expectation clears review",
       %{scope: scope} do
    draft = draft_fixture(scope)
    [first | _] = judgments(draft)
    assert {:ok, partial} = GuidedSetups.review(scope, draft.id, draft.revision, [first])
    assert GuidedSetups.state(scope, partial).stage == :checks
    assert partial.reviews[first["fingerprint"]]["output_text"] == "approved"
    assert partial.reviews[first["fingerprint"]]["case_key"] == "allow-case"
    edited = put_in(partial.raw, ["cases", Access.at(0), "expected"], "rejected")
    assert {:ok, changed} = GuidedSetups.save(scope, draft.id, partial.revision, edited)
    assert changed.reviews == %{}

    assert {:error, :proof_review_required} =
             GuidedSetups.review(scope, draft.id, changed.revision, [first])
  end
end
