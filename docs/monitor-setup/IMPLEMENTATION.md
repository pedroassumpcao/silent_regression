# Guided monitor setup — implementation plan

Approved: 2026-09-21. Scope: local product work; no deployment, live provider execution, or
external invitations. Each stage is independently verified and committed.

## Overview and prerequisites

Implement the guided journey approved in [UX assessment](UX_ASSESSMENT.md): connect a request →
add inputs and expected answers → confirm checks with examples → run once → review and finish.
Recurring execution is optional. [Original research](RESEARCH.md) records the existing architecture;
the assessment supersedes its user-facing flow, not its security or immutable-history guarantees.

Reuse the deterministic engines, exact provider-native request artifact, workspace/owner boundaries,
capture authorization and call ceilings, append-only snapshots, and reference compatibility checks.
Keep advanced authoring available. No AI authoring or exploratory execution mode is introduced.

## Stage summary

| Stage | Deliverable | Status |
| --- | --- | --- |
| 1 | Honest saving, safe check approval, and accurate progress | Complete |
| 2 | Clickable routing journey and JSON architecture check | Implemented; founder review pending |
| 3 | Coherent authoring draft, common journey, and routing recipe | Not started |
| 4 | Integrated first run, result review, and manual completion | Not started |
| 5 | JSON, sources, and text recipes plus contextual guidance | Not started |
| 6 | Independent usability validation and final corrections | Not started |

## Stage 1 — Correct misleading behavior

### Objective and rationale

Restore trust in saving, approval, and completion before changing the authoring architecture.
Resolve assessment findings U5–U7 and U11–U14's misleading labels; reduce U8's false finish line.

### Tasks

- [x] Submit current values on Save and exit; leave only after successful validation/persistence.
- [x] Preserve values on validation failure; show unsaved/saved status and link/reload navigation warnings.
- [x] Block proof mutations while rules are unsaved, and approval while any rules/proof edits are unsaved.
- [x] Require the exact reviewed draft/proof identity at the HTTP approval boundary; reject stale tabs.
- [x] Count active manual monitoring as complete, with recurring enablement reported separately.
- [x] Correct stale reference/rescore messaging, premature inspection progress, and internal task copy.
- [x] Label explicit exits accurately in analytics, not as abandonment.
- [x] Diagnose the existing UTC-reset scheduling test failure and restore date-independent verification.
- [x] Add regression coverage; run `mix precommit`; record results and focused commits.

### Success criteria and files

Changed form values survive Save and exit; invalid values remain on screen with an error and no success
claim. Unsaved rule changes cannot be approved/evaluated as though saved; stale reviewed revisions
cannot be approved. Manual completion reaches the final checklist milestone without scheduling.
Tests cover tenant boundaries and existing completed/revision paths. The only Stage 1 migration
expands the content-free event-name allowlist for manual readiness; no existing data is deleted.
Arbitrary incomplete draft storage belongs to Stage 3; invalid forms cannot yet be saved/left.
Inertia's link-navigation guard does not intercept browser back/forward history traversal; robust
draft recovery across that boundary remains part of Stage 3, not a claim of this immediate patch.

Likely files: Setup/Contract/Baseline/Operations React pages and tests, setup/contract controllers,
ContractAuthoring, PilotReadiness, ProductAnalytics, scheduling regression tests.

## Stage 2 — Design and validate the routing journey

### Objective and rationale

Make the entire first-value journey tangible before committing to new persistence/orchestration.

### Tasks

- [x] Build a zero-provider-call clickable prototype using the real allow/deny workflow.
- [x] Show one primary action per stage, inline guidance, expected/actual output, and save/return paths.
- [x] Include wrong allowed label, wrong expectation, provider failure, and member-to-owner handoff.
- [x] Check a structured JSON workflow against the same layout and draft concepts.
- [ ] Record founder feedback and an unfamiliar-user comprehension test when available.

### Success criteria and files

Reviewable prototype covers all five stages, including correction paths and explicit paid-call
authorization. Separate simulated data from real monitor execution. Record any unavailable external
research honestly; do not claim independent usability from automated tests.

Likely files: prototype UI/routes or local prototype artifact, this folder's design notes/test script.

Delivered: authenticated `/app/:workspace_slug/setup-preview`, isolated local simulation and tests.
See [prototype boundaries, walkthrough, JSON mapping and usability script](PROTOTYPE.md). Technical
verification is complete; founder feedback and available unfamiliar-user research are not yet recorded.

## Stage 3 — Common journey and routing recipe

### Objective and rationale

Replace scattered editors with a coherent mutable authoring draft without weakening execution history.

### Tasks

- [ ] Add bounded/versioned draft storage, recipe identity/version, optimistic concurrency and review state.
- [ ] Preserve partially entered JSON/lists; separate raw authoring values from executable validation.
- [ ] Derive authoritative journey stage, blockers, and next action server-side.
- [ ] Implement typed ordered request/messages, derived variable inputs, labels, and per-input expectations.
- [ ] Present exact rendered request preview; preserve advanced provider-native JSON and limits.
- [ ] Associate proposed proof outputs with cases and evaluate shared checks and case expectations separately.
- [ ] Require explicit user-confirmed judgments bound to exact case/check/output fingerprints.
- [ ] Seal monitor/case/contract snapshots transactionally only at the review/run boundary.
- [ ] Preserve existing approved history and successor configuration behavior; test stale tabs/reloads/tenancy.

### Success criteria and files

Routing can be authored without proprietary JSON or external instructions. A wrong allowed label
passes shared checks but fails its linked input expectation. No generated judgment is silently treated
as user ground truth. Existing immutable records remain readable and unchanged.

Likely files: additive migrations, Setup/draft schemas, MonitorSetups/journey context, proof preview,
React journey/recipe components, context/controller/component/browser tests.

## Stage 4 — First run, review, and manual readiness

### Objective and rationale

Make an understood result, not a locked configuration, the finish line.

### Tasks

- [ ] Coordinate owner check approval and explicit bounded baseline authorization, retaining separate audits.
- [ ] Reuse baseline execution and idempotency; resume the same attempt after refresh or double-click.
- [ ] Lead results with input → expected → actual → reason; disclose artifacts/usage/provenance on demand.
- [ ] Route wrong checks, wrong outputs, provider failures and member handoff to actionable recovery.
- [ ] Coordinate reference approval with manual activation; retain advanced exceptional acceptance.
- [ ] Show the initial capture in history; make Run again primary and Schedule checks optional.
- [ ] Separate first capture, result review, manual readiness, later runs, and recurring-enablement metrics.

### Success criteria and files

The first useful result needs no redundant run. Manual operation is complete, scheduling is explicit,
and provider calls occur only after authorization. Tests use fakes; live verification needs new approval.

Likely files: journey orchestration, Baselines/Captures/MonitorOperations, results UI, ProductAnalytics.

## Stage 5 — Remaining recipes and guidance

### Objective and rationale

Extend the same architecture to supported workflows without hiding their detection limits.

### Tasks

- [ ] Structured JSON: typed required fields/types and per-case values/ranges; flag unsupported schema features.
- [ ] Sources: allowed/required IDs and declared attribution; explain syntactic, not general factual, checking.
- [ ] Text: required/prohibited literals and explicit alternatives; explain paraphrase limitations.
- [ ] Provide user-reviewed local proof candidates and recipe-specific contextual examples.
- [ ] Update local walkthrough, demo links, revision guidance, and tests for all recipes.

### Success criteria and files

Each recipe explains what to enter and what it detects. Existing advanced rules remain supported;
historical approved contracts are not rewritten to match new defaults.

Likely files: recipe editors/compilers, proof proposals, tests, local walkthrough documentation.

## Stage 6 — Independent completion validation

### Objective and rationale

Verify the redesign solves the observed comprehension problem, beyond code correctness.

### Tasks

- [ ] Prepare a repeatable no-live-call usability script plus separately authorized real-workflow variant.
- [ ] Observe unfamiliar technical users; record assistance, backtracking, active time and wait time separately.
- [ ] Check understanding of correct rejection vs wrong route, call ceiling, save/resume and optional scheduling.
- [ ] Fix observed blockers; document evidence and remaining gaps before self-guided pilot onboarding.

### Success criteria and files

Use the assessment's tentative four-of-five supplied-flow target as a learning threshold, not a
conversion claim. External-user participation is a real pending dependency, not an automated-test result.

Likely files: usability script/findings, focused corrections and regression tests, progress log.

## Post-implementation and decisions

- [ ] Keep the alpha plan and local walkthrough linked to current progress.
- [ ] Verify keyboard/focus/loading/error states and responsive layout in a browser.
- [ ] Check bounded drafts, render cost, authorization/idempotency and immutable-history behavior.
- Data reset is authorized by the founder but not planned; prefer additive changes and preserve evidence.
- Deployment, real invitations/onboarding, and paid provider calls remain separate follow-ups.

References: [Inertia forms](https://inertiajs.com/docs/v2/forms),
[Inertia events](https://inertiajs.com/docs/v2/events),
[Ecto optimistic locking](https://ecto.hexdocs.pm/Ecto.Changeset.html#optimistic_lock/3).
