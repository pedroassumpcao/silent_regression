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

#### Task 16 schema decision

`provider_native_v1` deliberately supports text-only, stateless provider requests:

- OpenAI template keys are `instructions` and `input`; every input item has an allowlisted
  `user`, `assistant`, `system`, or `developer` role and string content.
- Anthropic template keys are `system` and `messages`; messages use alternating `user` and
  `assistant` roles, start and end with `user`, and use string content. Ending with `assistant`
  would be a provider prefill and is excluded because current models do not support it uniformly.
- Template strings may reference case input variables and the reserved `{{frozen_context}}`
  placeholder. Context is sent only when the customer puts that placeholder in a message.
- Provider/model, stateless storage settings, generation controls, and supported structured-output
  configuration remain server-owned allowlisted fields and appear in the exact preview.
- OpenAI supports the existing text, JSON object, and JSON schema modes. Anthropic supports text
  and JSON schema through `output_config.format`; its native mode rejects unconstrained
  `json_object` because the Messages API requires an actual schema for structured output.
- Multimodal blocks, tools, prompt caching, previous-response state, arbitrary headers, and
  arbitrary provider fields remain deferred. They must be added through a new request schema
  version rather than relaxed validation.

The provider-attempt ledger stores the exact secret-free endpoint/method/version/body artifact and
its SHA-256 fingerprint before each network call. The request body is behavior evidence and follows
the same customer-data retention boundary as prompts and case context; credentials and auth headers
are never included.

### Case-aware deterministic expectations

Each immutable case version should be able to declare bounded expectations such as:

- expected classification label or allowed alternatives;
- exact JSON Pointer values and typed comparisons;
- numeric values with explicit tolerance;
- required/allowed source identifiers;
- abstention requirements; and
- a separate result for every configured case check, while shared-rule outcomes stay on the
  contract layer.

Evaluation must bind an observation to the exact case expectation fingerprint. Expectations are
not executable code, regular expressions, or semantic scoring. Generic contract rules remain
useful for invariants shared by every case.

#### Task 17 schema decision

Case expectations are an optional, immutable layer beside the shared contract. Every case records
one of two explicit schema identities: `no_case_expectation` with an empty payload, or
`case_expectation_v1` with a bounded `checks` array. Every configured check has a stable ID and one
of five types:

- `label` compares the normalized whole output with one or more allowed case-specific labels;
- `json_value` resolves an RFC 6901 JSON Pointer and compares the typed value with one or more
  alternatives using explicit strict or mathematical numeric equality;
- `json_number` resolves a pointer and compares a numeric value with a target and non-negative
  tolerance;
- `source_ids` verifies required and allowed bracketed source identifiers, with an explicit
  at-least-one option; and
- `abstention` records whether an approved abstention alternative must be present or absent.

The schema excludes regular expressions, scripts, semantic similarity, arbitrary predicates, and
cross-case state. Payload size, check count, identifiers, pointers, alternatives, and evidence are
bounded. The expectation fingerprint covers the schema identity and normalized payload. Configured
expectations use a v2 case fingerprint that covers the expectation fingerprint; explicit
no-expectation cases retain the v1 behavior fingerprint. Existing case fingerprints remain
untouched so historical provenance stays reproducible and an otherwise unchanged legacy successor
does not become incompatible solely because the schema gained optional fields.

Capture evaluation keeps the shared-contract result and case-expectation result separate, while its
top-level status fails if either configured deterministic layer fails and becomes an evaluator error
if either layer cannot be evaluated safely. Historical contract rescoring reuses the immutable case
expectation attached to each observation.

Case import schema v1 remains accepted and produces `no_case_expectation`. Import schema v2 accepts
the optional expectation payload. Manual setup places a validated expectation JSON editor beside
each representative case; omission is deliberate and visibly labeled, never inferred from inputs.

The pointer and typed-value rules follow [RFC 6901](https://www.rfc-editor.org/info/rfc6901/) and
the JSON value/enum model documented by
[JSON Schema 2020-12](https://json-schema.org/draft/2020-12/json-schema-validation).

### Contract proof coverage, severity, and bounded activation

Task 18 keeps the existing bounded flat `all` authoring shape. It does not expose the engine's
general nested `all`/`any`/`not` expression tree. For the authored shape, proof coverage is explicit
for the aggregate root and every leaf rule:

- positive coverage means at least one complete, evaluator-confirmed fixture makes the rule pass;
- negative coverage means at least one complete, evaluator-confirmed fixture makes the rule fail;
- a critical leaf requires both positive and negative proof before approval;
- a warning leaf shows the same coverage facts, but missing proof is advisory rather than blocking;
  and
- an owner may waive missing proof for one critical rule only with a bounded rationale tied to the
  exact rule fingerprint. Any semantic edit invalidates that waiver.

The root `all` branch is reported for transparency but is derived from its children. Existing
known-valid/known-invalid requirements remain, while the rule matrix prevents a single negative
fixture from implying proof for untouched leaves. Coverage is computed only from fixtures whose
overall and per-rule judgments exactly match evaluator output.

Severity remains deterministic policy rather than a score. Missing `severity` means `critical` for
legacy compatibility. Authoring exposes `critical` and `warning`; captured rule evidence retains the
configured value; decisive critical failures create critical alerts and warning-only failures create
warning alerts. Severity does not turn a failed rule into a pass or suppress immutable evidence.

Historical rescore activation uses a durable, pinned work set rather than a growing timestamp-only
query. An owner approval request seals the candidate, creates a rescore run, materializes the exact
successful observation IDs visible at that boundary, and enqueues one serial Oban worker. The worker
processes a bounded batch, persists progress after every item, and snoozes itself until the pinned set
is complete. Only a successful final transaction retires the prior approved contract and activates
the candidate. Failure leaves the prior contract active and the failed candidate immutable. Initial
approval with no historical observations remains synchronous because there is no rescore work.

This uses Oban Basic features already in the repository. Individual insertion is retained where
uniqueness matters because bulk unique enforcement is an Oban Pro capability; no Pro-only workflow
or batch dependency is introduced.

### Recoverable operations

- Credential replacement is owner-authorized, validates affected models, updates future monitor
  references, and never rewrites historical observation provenance.
- Authentication recovery records a durable reset/recovery event and permits one explicitly
  authorized probe. Failure counting is bounded to the current breaker epoch.
- Capacity exhaustion becomes a visible waiting state with retry time and coverage notification,
  not a permanent safety pause.
- Workflow changes start from an immutable successor draft copied from the active configuration.
  Activation discloses reference invalidation and links back to the motivating review when present.

#### Task 19 credential-replacement boundary

Credential replacement is a staged activation rather than an immediate supersession:

- creating a successor keeps the predecessor usable until the owner activates the replacement;
- the credential screen shows every directly attached monitor and the active/draft model
  requirements that the replacement must satisfy;
- exact model-access results are stored per credential/model instead of relying on the credential's
  single last-validation summary;
- activation validates every distinct affected model with non-generative provider metadata calls,
  then locks the predecessor, successor, and affected monitors for one future-reference cutover;
- an in-progress capture or pending reference capture blocks cutover rather than cancelling or
  silently invalidating already-authorized work;
- capture runs, observations, and reference snapshots retain their original credential IDs; only
  `monitors.provider_credential_id` changes; and
- credential identity remains part of reviewed-reference compatibility. Active monitors are paused
  with `incompatible_configuration` at cutover and use the existing public replacement-reference
  and schedule flows to return to service.

Legacy rotations whose predecessor was already marked superseded remain recoverable through the
same activation operation. Existing successful exact-model validation summaries are backfilled into
the per-model table; no historical row or local workspace data is rewritten.

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

Task 18 finalized that schema as additive `proof_schema_version`/`proof_fingerprint` fields on
contract versions, exact-rule `contract_coverage_waivers`, and durable `contract_rescore_runs` plus
ordered `contract_rescore_items`. Legacy contract rows deliberately retain null proof fields; proof
is not invented retroactively. Candidates move through `pending_rescore` or `rescore_failed`, while
the one approved predecessor remains the execution source until a successful final activation
transaction.

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
