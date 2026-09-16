# Structured Review and Correction Progress

## Status: In Progress

## Quick Reference

- Research: `docs/structured-review/RESEARCH.md`
- Implementation: `docs/structured-review/IMPLEMENTATION.md`
- Parent plan: `plans/private_alpha_implementation_plan.md`, Task 13

## Phase Progress

### Phase 1: Review evidence foundation

**Status:** Completed

- Domain, evidence identity, supersession, concurrency, and authorization decisions recorded.
- Added exact alert/observation review targets, required reviewer attribution, bounded rationale, and
  explicit classification/action enums.
- Added database-enforced append-only history, one root per review stream, and one successor per
  decision so review chains cannot fork.
- Added optimistic expected-current validation, current/history queries, review counts, action
  counts, and changed-judgment counts.
- Verified attribution, supersession, false-negative capture, cross-workspace isolation, and
  database immutability with four focused tests.

### Phase 2: Governed alert and correction lifecycle

**Status:** Completed

- Alert resolution now requires a current alert review and permanently pins the exact decision used
  by the owner.
- Legacy resolved alerts remain readable, while the database rejects any new reviewed lifecycle
  transition that omits a resolution decision.
- Added immutable review-to-contract-draft origins, including idempotent reuse when a successor
  draft already exists.
- Confirmed members can review, acknowledge, and begin correction authoring while only owners can
  resolve alerts and approve contracts.

### Phase 3: Transactional contract rescore and compatibility

**Status:** Completed

- Extracted one immutable evaluation persistence path shared by normal capture completion and
  historical contract rescoring.
- Successor approval now deterministically rescores every stored successful observation inside the
  approval transaction, persists an immutable summary, and aborts activation on evaluator errors.
- Added a distinct contract-semantics fingerprint to capture and baseline provenance without
  rewriting the existing exact contract-snapshot fingerprint.
- Behavior-identical successors reuse the old approved baseline; semantic rule or evaluator changes
  make it incompatible and block new runs until a new baseline is approved.
- Verified both compatibility branches, zero additional provider calls, preserved old evaluations,
  new evaluation provenance, and summary immutability.

### Phase 4: Inertia review experience

**Status:** Completed

- Added run-level review counts explicitly labeled as human evidence rather than model accuracy.
- Added structured alert and observation review dialogs using the existing shadcn select, textarea,
  dialog, badge, button, card, and alert primitives.
- Added current judgment, append-only history, attribution, rationale, resulting action, stale-write
  feedback, and missed-regression entry points.
- Disabled owner resolution until a current judgment exists and exposed direct contract-revision
  handoff only for decisions that recorded that action.
- Added review-origin evidence and transactional rescore results to contract authoring.
- Kept review mutations inside the authenticated workspace-scoped route pipeline because their
  rationales and referenced outputs are private tenant data.

### Phase 5: Verification and handoff

**Status:** In progress

## Session Log

### 2026-09-16

- Audited Task 13 against capture, contract, baseline, alert, presenter, router, and frontend code.
- Selected append-only linear review chains with database-enforced non-forking supersession.
- Selected exact review-backed alert resolution and immutable contract-revision origins.
- Identified contract row identity as an overly strict baseline compatibility condition and defined
  semantic compatibility using fingerprints and execution identities.
- Confirmed that the existing shadcn select, textarea, dialog, alert, badge, button, and card
  primitives cover the review experience; no frontend dependency is required.
- Completed the review evidence foundation and began binding it to owner-governed alert resolution
  and versioned correction.
- Completed governed resolution and correction origins with 14 focused review, alert, and controller
  tests passing.
- Completed transactional historical rescoring and semantic baseline compatibility with 42 focused
  contract, baseline, capture, policy, and presenter tests passing.
- Completed the structured-review Inertia slice with 27 focused backend tests, TypeScript checking,
  and all 40 frontend tests passing.

## Blockers

- None.
