defmodule SilentRegression.GuidedRecipesTest do
  use SilentRegression.DataCase, async: true
  use Oban.Testing, repo: SilentRegression.Repo
  import SilentRegression.GuidedSetupsFixtures
  import SilentRegression.WorkspacesFixtures
  alias SilentRegression.{Captures, ContractAuthoring, GuidedSetups, Monitors, Repo}
  alias SilentRegression.GuidedSetups.{FirstRun, Proof, Recipes, Routing}

  setup do
    %{scope: workspace_scope_fixture()}
  end

  for recipe <- ~w(json sources text) do
    @recipe recipe
    test "#{recipe} keeps raw partial input, reviews both evaluators, seals complete proof and finishes one fake capture",
         %{scope: scope} do
      recipe = @recipe
      draft = recipe_draft_fixture(scope, recipe)
      assert {:ok, compiled} = Recipes.compile(draft)
      assert Enum.any?(compiled.proof, &(&1.shared == "pass" and &1.specific == "pass"))
      assert Enum.any?(compiled.proof, &(&1.shared == "fail"))
      assert Enum.any?(compiled.proof, &(&1.specific == "fail"))
      assert length(Proof.shared_fixtures(compiled.proof)) <= 20
      assert {:error, :draft_incomplete} = GuidedSetups.seal(scope, draft.id, draft.revision)

      partial = put_in(draft.raw, ["cases", Access.at(0), "expected"], "{")
      assert {:ok, incomplete} = GuidedSetups.save(scope, draft.id, draft.revision, partial)
      assert incomplete.raw == partial
      assert {:ok, draft} = GuidedSetups.save(scope, draft.id, incomplete.revision, draft.raw)

      assert {:error, :proof_review_required} =
               GuidedSetups.review(scope, draft.id, draft.revision, [
                 %{"fingerprint" => "forged", "shared" => "pass", "specific" => "pass"}
               ])

      assert {:ok, reviewed} =
               GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))

      assert GuidedSetups.state(scope, reviewed).reviewed
      assert {:ok, sealed} = GuidedSetups.seal(scope, reviewed.id, reviewed.revision)
      assert {:ok, same} = GuidedSetups.seal(scope, reviewed.id, 1)
      assert sealed.id == same.id
      assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 0
      assert {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)
      assert state.contract.readiness.ready?
      assert state.contract.coverage.ready?
      assert Enum.all?(state.contract.fixture_results, & &1.matches?)
      assert state.compiled.identity == compiled.identity

      assert {:ok, _} =
               FirstRun.approve_checks(scope, sealed.monitor_id, %{
                 "contract_id" => state.contract.contract_version.id,
                 "fingerprint" => state.contract.contract_version.fingerprint,
                 "coverage_fingerprint" => state.contract.coverage.fingerprint
               })

      assert {:ok, _} = FirstRun.validate_model(scope, sealed.monitor_id)
      {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)

      assert {:ok, snapshot} =
               FirstRun.authorize(scope, sealed.monitor_id, %{
                 "confirmed" => true,
                 "authorization_key" => Ecto.UUID.generate(),
                 "preview_fingerprint" => state.baseline.preflight.preview_fingerprint
               })

      Enum.each(
        snapshot.capture_run.observations,
        &Captures.execute_observation(snapshot.capture_run_id, &1.id)
      )

      {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)
      assert state.can_finish?

      assert {:ok, _} =
               FirstRun.finish(scope, sealed.monitor_id, %{
                 "confirmed" => true,
                 "snapshot_id" => snapshot.id,
                 "review_fingerprint" => state.review_fingerprint
               })

      {:ok, monitor} = Monitors.get_monitor(scope, sealed.monitor_id)
      assert monitor.state == :active
      assert monitor.cadence == :manual
      assert is_nil(monitor.next_run_at)
      assert Repo.aggregate(SilentRegression.Captures.CaptureRun, :count) == 1
      assert {:ok, correction} = FirstRun.corrected_draft(scope, sealed.monitor_id)
      assert correction.recipe == recipe
      assert correction.raw == sealed.raw
      assert correction.reviews == %{}
      assert is_nil(correction.monitor_id)
    end

    test "#{recipe} rejects stale proof, cross-workspace mutation and implicit recipe switching",
         %{scope: scope} do
      draft = recipe_draft_fixture(scope, @recipe)
      {:ok, reviewed} = GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))
      changed = put_in(draft.raw, ["instruction"], "Changed independently")
      assert {:ok, current} = GuidedSetups.save(scope, draft.id, reviewed.revision, changed)
      assert current.reviews == %{}

      assert {:error, :stale_draft} =
               GuidedSetups.save(scope, draft.id, reviewed.revision, changed)

      assert {:error, :proof_review_required} =
               GuidedSetups.review(scope, draft.id, current.revision, judgments(draft))

      assert {:error, :not_found} =
               GuidedSetups.save(workspace_scope_fixture(), draft.id, current.revision, changed)

      assert {:error, :invalid_draft} =
               GuidedSetups.save(
                 scope,
                 draft.id,
                 current.revision,
                 Map.put(changed, "recipe", "routing")
               )
    end
  end

  test "routing v1 identities, requests, roots and existing proof fingerprints are unchanged", %{
    scope: scope
  } do
    raw = raw_fixture(scope)
    {:ok, old} = Routing.compile(raw)
    {:ok, new} = Recipes.compile("routing", raw)
    assert Map.drop(old, [:proof]) == Map.drop(new, [:proof])
    assert old.proof == Enum.map(new.proof, &Map.delete(&1, :failed_rule_ids))
  end

  test "JSON distinguishes wrong values from types, covers each field, tolerances and false", %{
    scope: scope
  } do
    raw = recipe_raw_fixture(scope, "json")
    assert {:ok, compiled} = Recipes.compile("json", raw)
    assert Enum.any?(compiled.proof, &(&1.shared == "pass" and &1.specific == "fail"))

    for id <- ~w(valid_json field_1 field_2),
        do: assert(Enum.any?(compiled.proof, &(id in &1.failed_rule_ids)))

    [input] = compiled.version.cases

    for total <- [12.49, 12.5, 12.51] do
      assert evaluate(input, Jason.encode!(%{total: total, paid: false})).status == :pass
    end

    assert evaluate(input, ~s({"total":12.52,"paid":false})).status == :fail
    assert evaluate(input, ~s({"total":12.5,"paid":true})).status == :fail
    assert evaluate(input, ~s({"total":12.5,"paid":false,"extra":"allowed"})).status == :pass
  end

  test "JSON does not silently accept schemas, unused field values, types or invalid numeric input",
       %{scope: scope} do
    raw = recipe_raw_fixture(scope, "json")

    for settings <- [
          Map.put(raw["settings"], "$schema", "schema"),
          %{"fields" => [%{"key" => "nested/path", "type" => "string"}]},
          %{"fields" => [%{"key" => "total", "type" => "object"}]}
        ] do
      assert {:error, _} = Recipes.compile("json", Map.put(raw, "settings", settings))
    end

    values = Jason.decode!(hd(raw["cases"])["expected"])

    for invalid <- [
          Map.put(values, "extra", %{"value" => "1", "tolerance" => "0"}),
          put_in(values, ["total", "tolerance"], "-1"),
          put_in(values, ["total", "value"], "1e100")
        ] do
      assert {:error, _} =
               Recipes.compile(
                 "json",
                 put_in(raw, ["cases", Access.at(0), "expected"], Jason.encode!(invalid))
               )
    end
  end

  test "sources reject contradiction and independently expose missing, unknown and misplaced citations",
       %{scope: scope} do
    raw = recipe_raw_fixture(scope, "sources")
    {:ok, compiled} = Recipes.compile("sources", raw)
    assert Enum.any?(compiled.proof, &(&1.shared == "pass" and &1.specific == "fail"))

    for id <- ~w(allowed_sources required_sources fact_source),
        do: assert(Enum.any?(compiled.proof, &(id in &1.failed_rule_ids)))

    misplaced = Enum.find(compiled.proof, &String.starts_with?(&1.output, "[refunds]"))
    assert misplaced.shared == "fail"
    assert misplaced.specific == "pass"
    assert misplaced.failed_rule_ids == ["fact_source"]

    assert {:error, _} =
             Recipes.compile(
               "sources",
               put_in(raw, ["cases", Access.at(0), "expected"], "billing")
             )

    assert {:error, _} =
             Recipes.compile(
               "sources",
               put_in(raw, ["settings", "factText"], "Refunds within 30 days.")
             )

    assert {:error, _} = Recipes.compile("sources", put_in(raw, ["settings", "distance"], "2"))
  end

  test "text uses bounded normalized literals, not paraphrase or negation understanding", %{
    scope: scope
  } do
    raw = recipe_raw_fixture(scope, "text")
    {:ok, compiled} = Recipes.compile("text", raw)
    [input] = compiled.version.cases
    assert evaluate(input, "CANNOT—DETERMINE").status == :pass
    assert evaluate(input, "There is insufficient information").status == :pass
    assert evaluate(input, "I do not know").status == :fail
    # The limitation is intentional and disclosed: literal presence is not a semantic judgment.
    assert evaluate(input, "It is not true that we cannot determine").status == :pass

    for id <- ~w(required_language prohibited_language),
        do: assert(Enum.any?(compiled.proof, &(id in &1.failed_rule_ids)))

    assert {:error, _} =
             Recipes.compile(
               "text",
               put_in(raw, ["settings", "prohibitedText"], "consult a professional")
             )

    assert {:error, _} =
             Recipes.compile(
               "text",
               put_in(
                 raw,
                 ["cases", Access.at(0), "expected"],
                 "cannot determine\nCANNOT—DETERMINE"
               )
             )
  end

  test "20 cases per recipe stay under proof and persisted shared-fixture bounds", %{scope: scope} do
    for recipe <- ~w(json sources text) do
      raw = recipe_raw_fixture(scope, recipe)
      rows = for i <- 1..20, do: %{hd(raw["cases"]) | "key" => "case-#{i}", "name" => "Case #{i}"}
      assert {:ok, compiled} = Recipes.compile(recipe, %{raw | "cases" => rows})
      assert length(compiled.proof) <= 60
      assert length(Proof.shared_fixtures(compiled.proof)) <= ContractAuthoring.max_fixtures()
    end
  end

  test "maximum guided JSON fields and cases can persist their complete review without exceeding the database bound",
       %{scope: scope} do
    raw = recipe_raw_fixture(scope, "json")
    fields = for i <- 1..4, do: %{"key" => "field_#{i}", "type" => "string"}

    values =
      Map.new(fields, &{&1["key"], %{"value" => String.duplicate("x", 120), "tolerance" => ""}})

    cases =
      for i <- 1..20,
          do: %{
            hd(raw["cases"])
            | "key" => "case-#{i}",
              "name" => "Case #{i}",
              "expected" => Jason.encode!(values)
          }

    raw = %{raw | "settings" => %{"fields" => fields}, "cases" => cases}
    {:ok, draft} = GuidedSetups.create(scope, "json")
    {:ok, draft} = GuidedSetups.save(scope, draft.id, draft.revision, raw)

    assert {:ok, reviewed} =
             GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))

    assert map_size(reviewed.reviews) == 49
    assert {:ok, sealed} = GuidedSetups.seal(scope, draft.id, reviewed.revision)
    {:ok, state} = FirstRun.get_state(scope, sealed.monitor_id)
    assert state.contract.coverage.ready?
    assert length(state.contract.fixtures) == 6
  end

  defp evaluate(input, output),
    do:
      SilentRegression.CaseExpectations.evaluate(
        input.expectation_schema_version,
        input.expectation,
        input.expectation_fingerprint,
        output
      )
end
