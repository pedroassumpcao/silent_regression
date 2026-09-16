# Run Results and Alerts Progress

## Status: Phase 1 - In Progress

## Quick Reference

- Research: `docs/run-results-alerts/RESEARCH.md`
- Implementation: `docs/run-results-alerts/IMPLEMENTATION.md`
- Parent plan: `plans/private_alpha_implementation_plan.md`, Task 12

---

## Phase Progress

### Phase 1: Severity and Provenance

**Status:** In Progress

#### Tasks Completed

- Research and architecture decisions recorded.

#### Decisions Made

- Rule severity is optional and defaults to critical without normalizing old rule maps.
- New managed runs pin the compatible approved baseline; legacy missing provenance stays visible but
  is not compared.

#### Blockers

- None.

### Phase 2: Alert Domain and Policy

**Status:** Not Started

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

## Files Changed

- `docs/run-results-alerts/RESEARCH.md`
- `docs/run-results-alerts/IMPLEMENTATION.md`
- `docs/run-results-alerts/PROGRESS.md`
- `plans/private_alpha_implementation_plan.md`

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

