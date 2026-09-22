defmodule SilentRegression.GuidedSetupsFixtures do
  alias SilentRegression.{GuidedSetups, MonitorSetupsFixtures}
  alias SilentRegression.GuidedSetups.{Recipes, Routing}

  def raw_fixture(scope) do
    credential = MonitorSetupsFixtures.valid_credential_fixture(scope)

    Map.merge(Routing.empty(), %{
      "name" => "Approval routing",
      "provider" => "openai",
      "model" => "gpt-5.6-luna",
      "credentialId" => credential.id,
      "instruction" => "Return approved for allow, rejected for deny. Only the label.",
      "messages" => [%{"role" => "user", "content" => "{{action}}"}],
      "labelsText" => "approved\nrejected",
      "cases" => [
        %{
          "key" => "allow-case",
          "name" => "Allowed action",
          "variables" => %{"action" => "allow"},
          "context" => "",
          "expected" => "approved"
        },
        %{
          "key" => "deny-case",
          "name" => "Denied action",
          "variables" => %{"action" => "deny"},
          "context" => "",
          "expected" => "rejected"
        }
      ]
    })
  end

  def draft_fixture(scope) do
    {:ok, draft} = GuidedSetups.create(scope)
    {:ok, draft} = GuidedSetups.save(scope, draft.id, draft.revision, raw_fixture(scope))
    draft
  end

  def recipe_raw_fixture(scope, recipe) when recipe in ~w(json sources text) do
    common = raw_fixture(scope) |> Map.delete("labelsText")

    {settings, expected} =
      case recipe do
        "json" ->
          {%{
             "fields" => [
               %{"key" => "total", "type" => "number"},
               %{"key" => "paid", "type" => "boolean"}
             ]
           },
           Jason.encode!(%{
             "total" => %{"value" => "12.5", "tolerance" => "0.01"},
             "paid" => %{"value" => "false", "tolerance" => ""}
           })}

        "sources" ->
          {%{
             "allowedText" => "billing\nrefunds",
             "requiredText" => "refunds",
             "factText" => "Refunds within 30 days",
             "factSourceId" => "refunds",
             "distance" => "100"
           }, "refunds"}

        "text" ->
          {%{
             "requiredText" => "Consult a professional",
             "prohibitedText" => "guaranteed outcome"
           }, "cannot determine\ninsufficient information"}
      end

    row = %{
      hd(common["cases"])
      | "expected" => expected,
        "variables" => %{"action" => "[fake:recipe=#{recipe}] input"}
    }

    Map.merge(common, %{
      "settings" => settings,
      "cases" => [row],
      "name" => "Guided #{recipe}",
      "instruction" => "Use the supplied input."
    })
  end

  def recipe_draft_fixture(scope, recipe) do
    {:ok, draft} = GuidedSetups.create(scope, recipe)

    {:ok, draft} =
      GuidedSetups.save(scope, draft.id, draft.revision, recipe_raw_fixture(scope, recipe))

    draft
  end

  def judgments(draft) do
    {:ok, compiled} = Recipes.compile(draft)

    Enum.map(
      compiled.proof,
      &%{
        "fingerprint" => &1.fingerprint,
        "shared" => &1.proposed_shared,
        "specific" => &1.proposed_case
      }
    )
  end

  def reviewed_fixture(scope) do
    draft = draft_fixture(scope)
    {:ok, draft} = GuidedSetups.review(scope, draft.id, draft.revision, judgments(draft))
    draft
  end
end
