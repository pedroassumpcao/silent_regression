defmodule SilentRegression.Providers.UsabilityOpenAI do
  @moduledoc "Test-only fixed responses for the Stage 6 study cards; never calls a network."
  @behaviour SilentRegression.Providers.Adapter
  alias SilentRegression.Providers.{CompletionResult, Failure, FakeOpenAI}

  @secrets ~w(sk-usability-pass sk-usability-wrong-route sk-usability-failure)
  @outputs %{
    "allow" => "approved",
    "deny" => "rejected",
    "Invoice A: total 12.50; unpaid" => ~s({"total":12.5,"paid":false}),
    "What is the refund window?" => "Refunds within 30 days [refunds]",
    "Can you guarantee an outcome?" => "Consult a professional. Cannot determine"
  }

  @impl true
  def request_provenance, do: FakeOpenAI.request_provenance()

  @impl true
  def validate_credential(secret, options) when secret in @secrets,
    do: FakeOpenAI.validate_credential(secret, options)

  def validate_credential(_, _),
    do: failure(:authentication, "Use a fictional study credential, never a real key.")

  @impl true
  def complete_once("sk-usability-failure", _, _),
    do: failure(:provider_unavailable, "Simulated provider failure; no network request occurred.")

  def complete_once(secret, request, _) when secret in @secrets do
    # Read only the supplied input, never the evaluator, cases or expected answers. This is a
    # fixed lookup, not a model: changes to instructions cannot repair a simulated wrong route.
    with [%{"role" => "user", "content" => input}] when is_binary(input) <-
           get_in(request.request_artifact, ["body", "input"]),
         output when is_binary(output) <- Map.get(@outputs, String.trim(input)) do
      output =
        if secret == "sk-usability-wrong-route" and String.trim(input) == "allow",
          do: "rejected",
          else: output

      {:ok,
       %CompletionResult{
         provider: :openai,
         requested_model: request.requested_model,
         returned_model: request.requested_model,
         output_text: output,
         request_id: "usability_fake_#{request.client_request_id}",
         completion_state: :complete,
         input_tokens: 10,
         output_tokens: 5,
         latency_ms: 1,
         finish_reason: "completed",
         captured_at: DateTime.utc_now(),
         metadata: %{"synthetic_usability_fixture" => true}
       }}
    else
      _ ->
        failure(
          :invalid_request,
          "Study fixture not recognized. Use the supplied task-card input."
        )
    end
  end

  def complete_once(_, _, _),
    do: failure(:authentication, "Use a fictional study credential, never a real key.")

  defp failure(category, message),
    do: {:error, %Failure{category: category, message: message, attempts: 1, latency_ms: 1}}
end
