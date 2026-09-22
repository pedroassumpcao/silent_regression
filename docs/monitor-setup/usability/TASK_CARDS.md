# Participant cards — supply one card at a time

This session uses fictional data and a fake provider. It makes no paid model calls. The screens are
the current saved setup product, but the provider's responses are fixed for these activities. Please
do not enter real keys or customer data. We are testing the product, not you. Explain what you are
trying to do and anything that is unclear. You can pause or stop at any time.

The facilitator has signed you in and supplied the connection. No walkthrough is required.

## A — Protect an approval workflow (first activity)

Your service returns `approved` for an `allow` action and `rejected` for a `deny` action, with no
additional explanation. You want to notice if the service stops following that policy.

Set up a monitor using both examples, inspect its first evaluated result, and leave it ready for
checks you start yourself. You do not want automatic recurring checks. Tell us when you think you
are finished and what the result tells you.

Supplied request data (not UI instructions):

- Provider: OpenAI; model label: `gpt-5.6-luna` (simulated for this session).
- Connection: `FAKE study connection — no live calls`.
- Instruction: `Return approved for allow and rejected for deny. Return only the label.`
- One user message: `{{action}}`.
- Inputs: `action=allow` should return `approved`; `action=deny` should return `rejected`.
- Maximum output tokens: 512. Other optional settings/context may stay empty.
- Give the monitor any fictional name you can recognize later.

## B — Leave work unfinished, then return (after activity A)

Begin a separate monitor for the same policy. You have started entering an example but do not yet
know its answer. Leave the unfinished work safely, refresh the page, then find it again and continue.
Tell us what was saved and what still needs to be done. Do not run this extra monitor.

## C — A result needs investigation (facilitator supplies the result)

This monitor has produced an unexpected result. Work out whether the output, the declared expectation,
or the execution failed. Show what you would do next and where the previous evidence remains.
Do not change a business requirement merely to make the status pass.

## D — Invoice extraction (optional second recipe)

Monitor a service that extracts two required fields: numeric `total` and boolean `paid`. For the
invoice below, you know the total is 12.50 (an absolute difference up to 0.01 is acceptable) and the
invoice is unpaid. Extra fields are acceptable. Configure the checks and inspect the proposed examples.
Do not run yet; explain what the checks would and would not detect.

- Same provider, model label and connection as A.
- Instruction: `Return only raw JSON with numeric total and boolean paid from the invoice.`
- One user message: `{{invoice}}`.
- Invoice: `Invoice A: total 12.50; unpaid`.

## E — Answers with source references (optional second recipe)

Your answer service uses source IDs `billing` and `refunds`. For this question, it must cite only
`refunds`. You also require the phrase `Refunds within 30 days` to be followed by `[refunds]` within
100 characters. Configure and review these checks. Explain what a passing result establishes.

- Same provider, model label and connection as A.
- Instruction: `Policy: Refunds within 30 days. Source ID: refunds. Answer with that statement and its bracketed source ID.`
- One user message: `{{question}}`.
- Question: `What is the refund window?`.
- No separate context is needed for this fictional request; its policy is in the instruction.

## F — Required and prohibited wording (optional second recipe)

Your service must include `Consult a professional` and must not include `guaranteed outcome`.
For the question below, either `cannot determine` or `insufficient information` is an acceptable
literal answer. Configure and review the checks. Explain what a passing result establishes.

- Same provider, model label and connection as A.
- Instruction: `Do not promise an outcome. Include Consult a professional and say Cannot determine when evidence is insufficient.`
- One user message: `{{question}}`.
- Question: `Can you guarantee an outcome?`.

## G — Your own workflow (separate, authorized session only)

Choose one real use case for which you can independently specify acceptable behavior. Use sanitized
inputs that you are permitted to share. Try to express that request and its requirements in the app.
Tell us where the requirements are hard to define or unsupported. Stop before model access checks or
execution until the owner/facilitator confirms the separate authorization. Do not copy a generated
answer into the expectations simply because the model produced it.
