# Stage 6 — independent usability study

Protocol v1, 2026-09-22. Status: preparation; **zero unfamiliar-user sessions recorded**.
Owner/facilitator: Pedro. This is a formative study, not a conversion experiment or a pilot launch.

## What we need to learn

Can a technical person who did not build the app create a monitor, understand its evaluated result,
and finish ready for on-demand checks without being taught the UI? In particular, do they distinguish
a correct business rejection from a wrong route, synthetic proof from provider output, and on-demand
operation from free/simulated execution? Scheduling must be understood as optional.

The onboarding skill informs the first-understood-result milestone; the build skill keeps technical
verification separate from human evidence. Do not equate finishing a form or approving every proposal
with understanding. Scope remains the approved [Stage 6](../IMPLEMENTATION.md#stage-6--independent-completion-validation).

## Study kit

- [Participant task cards](TASK_CARDS.md): give only the current card, not the answers below.
- [Facilitator script and scoring](FACILITATOR.md): preparation, neutral questions and answer rubric.
- [Session template](SESSION_TEMPLATE.md): copy into private research storage, not straight into Git.
- [Findings and release decision](FINDINGS.md): sanitized evidence, counts, corrections and retest.
- [Actual product walkthrough](../GUIDED_SETUP.md): facilitator reference; withhold during the first attempt.

## Participants and sessions

Start with five technical people unfamiliar with the product: engineers or technical product/QA
owners who have configured LLM calls and can supply known answers. Do not require evaluation-tool
expertise. Record prior exposure to the product or walkthrough. Founder, implementation-agent and
previously coached attempts are rehearsals, not part of the five first-time observations.

Plan 35–45 minutes each: consent/background, supplied routing task, comprehension/recovery, and one
optional recipe matched to their experience. All five do routing first for a comparable first-time
signal; later recipes are learned-use evidence, not another cold-start score. Across the study, aim
to inspect JSON, sources and text at least once; state any recipe not observed. Accessibility needs
and the participant's usual input methods should be accommodated, not treated as failure.

No recruitment messages or invitations are sent by this kit. The founder arranges participants.
In-person testing can use this local machine; remote screen control must be arranged deliberately.
Do not publish a tunnel or expose the sandbox to the network. A participant watching you click is an
assisted walkthrough, not an independent completion attempt.

## Repeatable no-live-call sandbox — current product, not the old preview

From the repo root, after the normal dependencies/Postgres are available:

```sh
mix assets.build
MIX_ENV=test MIX_TEST_PARTITION=_usability mix run --no-start --no-halt test/support/start_usability.exs rehearsal01
```

The runner creates/migrates only `silent_regression_test_usability`, starts at
`http://127.0.0.1:4010`, and prints a fictional login and start URL. It seeds an owner workspace and
one fake validated OpenAI connection, **no monitor, draft, proof judgment or approved result**.
Sign in with the printed fictional email and test password, then open the printed Monitors URL.
Use a separate browser profile/window, close unrelated tabs, and verify the workspace says **FAKE study**.
This also avoids login-cookie interference with another local Phoenix server.

Before a participant, stop with Ctrl-C twice, rerun with `p01`, `p02`, etc., and sign in as that printed
account. The same ID resumes its existing records without resetting passwords, credentials or drafts.
A new ID creates a separate workspace; never reuse the founder rehearsal as a first-time participant.
The database is retained on exit. No automatic delete/reset is included. Never run `mix test` with
this study partition: it is the retained study sandbox, not the ordinary disposable test database.

Safety properties:

- Requires `MIX_ENV=test`, the exact `_usability` partition, local database name/host and test mailer;
  refuses a running application, live adapters or database URL override before creating/migrating.
- Overrides the endpoint to loopback port 4010, regardless of `PORT`. No production config changes.
- Only capture workers run. Scheduler, notification, maintenance/rescore queues and cron are off.
- OpenAI calls resolve to `UsabilityOpenAI`; Anthropic stays on its existing test fake. Neither uses
  a real provider. Only the OpenAI task cards are supported by this study; arbitrary workflows are not.
- Keys, model names, usage, request IDs and latencies are fictional. No billing or live model-access
  evidence is produced. Do not paste real keys, customer prompts, documents or personal data.
- Fixed outputs come from the supplied input, never the participant's expectation or evaluator result.
  Prompt edits do not change the fake's behavior. Unrecognized inputs fail explicitly; record a
  fixture-limitation failure separately from an app usability failure.

The normal application UI, saved drafts, request rendering, deterministic engines, approvals,
capture jobs, result review and finish are real **inside this isolated test database**. This is not
the historical `/setup-preview` simulator. No study data moves to development/production automatically.
The app uses its normal real-product authorization wording; the prebrief must say the provider is fake.
Do not infer that fake-runtime timing measures production latency or that preseeded access tests credential onboarding.

### Rehearsal checklist

- [ ] Pin protocol version and code commit in the session record; rebuild assets on that commit.
- [ ] Verify printed DB, loopback URL, FAKE workspace and correct participant login.
- [ ] Run the routing card as `rehearsal01`, not a participant; check allow/deny results and scheduling off.
- [ ] Exercise incomplete save/exit and refresh/resume; record technical problems before recruiting.
- [ ] Check browser console and stop if the study cannot be performed reliably.
- [ ] Start a new participant ID with empty drafts/monitors; do not give them this walkthrough.
- [ ] Obtain consent for notes and separate optional recording before observation.

## Separately authorized real-workflow variant

This variant is **not executed or authorized by Stage 6 preparation**. Do not switch the sandbox's
adapters, database or keys to live. Use the normal local development app and a deliberately selected
workspace with its real owner; deployment and real partner invitations remain separate follow-ups.

1. Finish the supplied-flow observation first. Record own-workflow work as a separate session/phase.
2. Ask the owner for one genuine bounded workflow: exact supported provider request/model/settings,
   sanitized representative input(s), independently known expectations, and permission to retain them
   and send the rendered content to that provider. If expectations cannot be specified, record this
   as a product-fit/authoring finding; do not invent requirements or infer them from generated output.
3. Get explicit approval for any credential/model-access verification separately. Keep secrets in the
   normal credential form, never session notes. Current model availability is verified in that environment.
4. Author/review through the normal guided path. Read back the exact workspace/monitor, provider/model,
   case count, samples, maximum completion attempts including retries, and separate metadata calls from
   the actual preview. The maximum is not a promised spend or exact price.
5. Request authorization for **one** bounded capture of that exact configuration. Record who approved,
   when, and the scope/preview identity without secrets. Absent approval, stop before the call; score
   only the authoring/comprehension portions. A general earlier smoke approval does not cover this run.
6. Observe results honestly, including provider failures and incorrect outputs. Never weaken a correct
   check to get a green finish. Owner review/acceptance remains separate; retry or another monitor needs
   new applicable authorization. Leave scheduling off and do not run a second capture for appearances.
7. Record credential acquisition, metadata/provider waits, active authoring and expectation research
   separately. Own-workflow results are not pooled into the supplied-flow four-of-five target.

## Decision rule and limits

Tentative learning threshold from the assessment: four of five first-time participants complete the
supplied flow unaided in about 10 active minutes **and demonstrate understanding**, excluding preseeded
credentials and provider waits. We operationalize “about” as ≤10 minutes for the recorded count; keep
individual times and near-misses visible rather than rounding them into successes. The 10-minute
number is not a timeout: allow up to 15 active minutes before offering a rescue, and count that separately.

Record all eligible attempts, including failures, withdrawals and partial completions. No percentage
claim for the market and no statistical conversion/retention claim follows from five people. Human
consent may require removing an observation; disclose an exclusion without preserving identifying details.

To close Stage 6: collect observations, score the rubric, inspect save/resume and recovery, triage issues,
fix blocking/safety misunderstandings and retest. A failed target keeps the self-guided gate open or
requires an explicit documented founder decision to remain concierge-assisted. It is not “passed”
because code tests pass. Changes between participants must be recorded by build/cohort; a later fresh
cohort is needed for a claim that a revised flow meets the threshold. Repeat participants test fixes,
not first-time comprehension. Existing deployment/Gate D requirements remain unchanged.

## Research practice references

Use goal-based tasks and neutral observation rather than instructions naming the controls being tested;
the local rubric and thresholds above are our product hypotheses, not source benchmarks.
[GOV.UK moderated usability testing](https://www.gov.uk/service-manual/user-research/using-moderated-usability-testing),
[NN/g task scenarios](https://www.nngroup.com/articles/task-scenarios-usability-testing/).

Get consent before notes/recording and separate observed behavior from interpretation. Store identifiable
research privately with agreed access/retention; commit only sanitized findings.
[GOV.UK research notes and recordings](https://www.gov.uk/service-manual/user-research/taking-notes-and-recording-user-research-sessions).
