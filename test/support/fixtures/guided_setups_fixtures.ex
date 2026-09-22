defmodule SilentRegression.GuidedSetupsFixtures do
  alias SilentRegression.{GuidedSetups, MonitorSetupsFixtures}
  alias SilentRegression.GuidedSetups.Routing

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

  def judgments(draft) do
    {:ok, compiled} = Routing.compile(draft.raw)

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
