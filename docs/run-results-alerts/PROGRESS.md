# Run Results and Alerts Progress

## Status: Phase 2 - In Progress

## Quick Reference

- Research: `docs/run-results-alerts/RESEARCH.md`
- Implementation: `docs/run-results-alerts/IMPLEMENTATION.md`
- Parent plan: `plans/private_alpha_implementation_plan.md`, Task 12

---

## Phase Progress

### Phase 1: Severity and Provenance

**Status:** Completed

#### Tasks Completed

- Research and architecture decisions recorded.
- Optional rule severity is parsed, evaluated, serialized, and persisted without normalizing old
  contract maps.
- New managed runs pin the exact compatible baseline snapshot, and the database protects that link
  as immutable plan provenance.
- Existing managed runs are conservatively backfilled only when every provenance field matches an
  approved or superseded snapshot that predates the run.

#### Decisions Made

- Rule severity is optional and defaults to critical without normalizing old rule maps.
- New managed runs pin the compatible approved baseline; legacy missing provenance stays visible but
  is not compared.

#### Blockers

- None.

### Phase 2: Alert Domain and Policy

**Status:** In Progress

#### Tasks Completed

- None.

#### Decisions Made

- One content alert per failed evaluation; operational findings group by run and code.
- Database uniqueness is the final idempotency boundary.

#### Blockers

- None.

### Phase 3: Result Queries and Presenters

**Status:** Not Started

#### Tasks Completed

- None.

#### Decisions Made

- Diagnostic maps are allowlisted and all browser-bound free text is UTF-8-safe and bounded.

#### Blockers

- None.

### Phase 4: Inertia Product Experience

**Status:** Not Started

#### Tasks Completed

- None.

#### Decisions Made

- Add a workspace alert inbox, monitor results page, and run detail page using existing primitives.

#### Blockers

- None.

### Phase 5: Verification and Handoff

**Status:** Not Started

#### Tasks Completed

- None.

#### Decisions Made

- Browser verification uses the fake provider and makes zero live provider calls.

#### Blockers

- None.

---

## Session Log

### 2026-09-16

- Reconciled Task 12 with existing capture, baseline, and scheduling boundaries.
- Defined alert categories, severities, identities, lifecycle permissions, and conservative
  baseline-relative operational thresholds.
- Kept mechanical acknowledgement/resolution in Task 12 and append-only human judgment in Task 13.
- Completed Phase 1 severity and baseline-provenance implementation with focused parser, evaluator,
  capture-schema, capture-execution, and monitor-operation tests.

## Files Changed

- `docs/run-results-alerts/RESEARCH.md`
- `docs/run-results-alerts/IMPLEMENTATION.md`
- `docs/run-results-alerts/PROGRESS.md`
- `plans/private_alpha_implementation_plan.md`
- `docs/contracts/deterministic-contract-v1.schema.json`
- `lib/silent_regression/contracts/parser.ex`
- `lib/silent_regression/contracts/evaluator.ex`
- `lib/silent_regression/contracts/rule_result.ex`
- `lib/silent_regression/captures.ex`
- `lib/silent_regression/captures/capture_run.ex`
- `lib/silent_regression/captures/capture_rule_result.ex`
- `priv/repo/migrations/20260916180310_add_result_alert_foundations.exs`

## Architectural Decisions

- A deterministic contract failure is a content finding; provider/model/metric/provenance/evaluator
  findings are operational.
- No unexplained quality score will be introduced.
- Alert generation runs after durable capture execution and is safe to retry.

## Lessons Learned

- Capture runs already freeze most comparison provenance, but they need the baseline snapshot ID to
  make the comparison historically unambiguous.
- The existing temporary runs-needing-attention count is intentionally replaced rather than evolved
  into a second alert system.
