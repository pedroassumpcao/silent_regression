# Design-review hardening research

## Overview

The Sol and Astra reviews agree that Silent Regression has strong evidence, tenancy, spend-control,
and human-review foundations, but the first pilot should not start until the monitored request is
faithful, ordinary failures are recoverable, and the product makes only claims its deterministic
engine can prove.

This program keeps the product narrow: scheduled deterministic conformance testing for a
customer-supplied provider request. It does not add semantic judges, live-traffic ingestion,
billing, more providers, or enterprise administration.

The accepted review sources are:

- [Sol design review](../design-reviews/2026-09-16-sol.md)
- [Astra design review](../design-reviews/2026-09-16-astra.md)

## Accepted product decisions

1. Use provider-native, versioned message templates and an allowlisted set of provider fields. The
   exact provider-visible request must be previewable and fingerprinted; Silent Regression must not
   add an undisclosed prompt wrapper.
2. Add case-specific deterministic expectations so a valid shape or allowed label is not mistaken
   for the correct answer to a particular case.
3. Add ordinary recovery paths for credential replacement, authentication breakers, temporary
   capacity exhaustion, and changed workflow configuration.
4. Group recurring failures into incidents while retaining observation-level evidence.
5. Keep baseline capture, but describe it accurately as a reviewed reference capture for
   provenance and operational comparisons. It is not a statistical content distribution.
6. Require contract proof coverage at the rule level and expose supported severity controls.
7. Correct public copy that implies unsupported wildcard or universal claim verification.
8. Make clean-checkout verification reproducible and include the frontend/toolchain in the gate.
9. Complete Gates A through D before inviting the first external design partner.

## Current implementation evidence

| Area | Current behavior | Consequence |
| --- | --- | --- |
| Request construction | Product execution converts input to a spike case and adds `Context`, `Question`, and `Response requirements` sections | The replay can differ materially from the customer's production request |
| Evaluation input | The evaluator receives contract and output, but no case expectation | It can validate an allowed value without proving it is correct for that case |
| Credential rotation | Rotation creates a successor credential but existing monitors retain the superseded reference | A routine security operation can strand monitoring |
| Authentication breaker | Recent auth failures pause execution without a user-visible recovery epoch/probe | The monitor can enter a state it cannot clear through ordinary operations |
| Capacity exhaustion | A scheduled refusal can become a persistent pause and one run-cap error is mislabeled | Temporary limits can silently remove coverage |
| Workflow changes | Immutable versions exist, but completed setup is effectively one-shot | Users can revise a contract but not the prompt, cases, context, or model in place |
| Alerts | Identity includes the run, so recurring failures create new alerts and deliveries | Persistent failures can flood the review queue |
| Contract proof | Approval needs passing and failing fixtures globally, not negative proof per rule | Untested rules can be approved |
| Historical rescore | Approval loads and evaluates all retained observations synchronously while holding activation work | Correction cost grows with successful product use |
| Public example | The homepage claims every factual claim is checked and displays a wildcard-like path | The marketing surface overstates evaluator capability |
| Reproducibility | Committed tests reference ignored benchmark artifacts; `mix precommit` omits frontend/build checks | A clean checkout does not prove the claimed gate |

The replacement-baseline lifecycle found after the reviews is already corrected and verified. It
remains a useful pattern: preserve old evidence, make incompatibility explicit, and activate a
successor only after deliberate approval.

## Technical approach

### Provider-native request artifact

The versioned unit should be the request customers recognize from their provider integration, not
a reconstructed question/context abstraction:

- ordered message/input items with provider-supported roles and content;
- explicit system/developer instructions where the provider supports them;
- allowlisted generation and response-format fields;
- case variables substituted into declared template locations;
- a canonical redacted preview and behavior fingerprint derived from the effective request; and
- a final payload-level receipt that proves what was sent without persisting secrets.

OpenAI's Responses API accepts ordered input items/messages, while Anthropic separates its system
instruction from an ordered `messages` list. The product can normalize authoring concepts without
pretending the wire payloads are identical:

- [OpenAI Responses quickstart](https://platform.openai.com/docs/quickstart/make-your-first-api-request)
- [OpenAI Responses API reference](https://platform.openai.com/docs/api-reference/responses)
- [Anthropic prompt templates and variables](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/prompt-templates-and-variables)

Legacy monitor versions must stay reproducible under a named `legacy_wrapped_v1` request mode.
They must never be silently reinterpreted as provider-native requests.

### Case-aware deterministic expectations

Each immutable case version should be able to declare bounded expectations such as:

- expected classification label or allowed alternatives;
- exact JSON Pointer values and typed comparisons;
- numeric values with explicit tolerance;
- required/allowed source identifiers;
- abstention requirements; and
- expected deterministic rule outcomes where that remains useful.

Evaluation must bind an observation to the exact case expectation fingerprint. Expectations are
not executable code, regular expressions, or semantic scoring. Generic contract rules remain
useful for invariants shared by every case.

### Recoverable operations

- Credential replacement is owner-authorized, validates affected models, updates future monitor
  references, and never rewrites historical observation provenance.
- Authentication recovery records a durable reset/recovery event and permits one explicitly
  authorized probe. Failure counting is bounded to the current breaker epoch.
- Capacity exhaustion becomes a visible waiting state with retry time and coverage notification,
  not a permanent safety pause.
- Workflow changes start from an immutable successor draft copied from the active configuration.
  Activation discloses reference invalidation and links back to the motivating review when present.

### Incident-centered alerts

Observations and evaluations remain immutable. A mutable incident groups the actionable lifecycle
for the same monitor, configuration, case/rule signature, and failure kind. Occurrences record
successive runs. Notifications distinguish a new incident, bounded recurrence updates, and
recovery.

## Data-model impact

A local data wipe is **not required or recommended**. The changes can be additive and the existing
data provides valuable migration and compatibility coverage.

| Area | Expected schema impact | Migration strategy |
| --- | --- | --- |
| Request fidelity | Add request mode/schema and provider-native template data to `MonitorVersion`; exact fields finalized in Task 16 | Backfill existing versions as `legacy_wrapped_v1`; freeze their current fingerprints and behavior |
| Case expectations | Add versioned expectation data/schema identity to `CaseVersion`, and expectation provenance to evaluations/results if needed | Existing cases mean `no_case_expectation`; no inferred answers |
| Credential replacement | Existing credential and monitor references may be sufficient; an explicit replacement audit/link may be added | Update only future execution reference in a transaction; keep historical IDs |
| Auth recovery | Add a breaker epoch/reset event or equivalent durable state | Existing failure history remains evidence; only the evaluation window changes |
| Capacity coverage | Add explicit waiting/retry/coverage state or events if current monitor fields cannot represent it cleanly | Backfill active/paused monitors conservatively from current state |
| Successor configuration | Existing immutable versions are reusable; add draft/origin/motivation linkage where required | Copy active version and cases into a draft, then activate atomically |
| Incidents | Add incident and occurrence records; retain alerts during transition | Backfill or lazily attach open alerts by stable signature; do not discard alerts |
| Bounded rescore | A durable rescore job/cutoff may need progress state associated with a draft contract version | Pin the observation cutoff and activate only after the bounded rescore completes |
| Public copy, reference terminology, proof UI, CI | No domain migration | Code/documentation changes only |

Before each schema-bearing task, tests must exercise the migration against a database containing
legacy monitor, run, baseline, alert, and review history. Destructive reset remains an explicit
last resort, not an implementation shortcut.

## UX direction

- Show an exact per-case provider request preview before spend authorization.
- Put case expectations next to representative inputs instead of making users infer them through a
  global rule language.
- Present contract coverage as proven, waived, or missing for every rule and severity.
- Show bounded historical-rescore progress and keep the prior approved contract active until success.
- Name the baseline step “Review reference capture” in customer-facing copy and explain what it can
  and cannot establish.
- Show “waiting for capacity,” “authentication recovery required,” and “credential replacement
  required” as distinct states with one next action.
- Make an incident the primary review object while preserving links to every occurrence and exact
  observation.

## Risks and boundaries

- Provider-native fidelity still cannot reproduce customer preprocessing, retrieval, tools, or
  postprocessing that the customer does not provide. The UI must state the monitored boundary.
- Provider schemas evolve. Persist schema versions and allowlisted fields rather than arbitrary
  payload passthrough.
- Case expectations can become onerous. Begin with the objective workflows already in scope and
  use imports/demos to reduce authoring friction after the core semantics are sound.
- Incident grouping must not suppress a materially new failure. Its signature and recurrence rules
  require held-out tests.
- Recent-auth and production operations are first-pilot gates, but broad enterprise controls remain
  deferred.
