# Run Results and Alerts Progress

## Status: Phase 4 - Completed

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

**Status:** Completed

#### Tasks Completed

- Added immutable alert evidence with open, acknowledged, and resolved database-enforced states.
- Added idempotent terminal-run synchronization through database uniqueness and the observation
  worker retry path.
- Implemented deterministic content findings, grouped provider/model/completion/evaluator findings,
  and conservative baseline-relative latency/usage warnings.
- Added member acknowledgement, owner-only resolution, actor timestamps, and audit events.
- Verified cross-workspace isolation, immutable evidence, forward-only lifecycle, and retry safety.

#### Decisions Made

- One content alert per failed evaluation; operational findings group by run and code.
- Database uniqueness is the final idempotency boundary.

#### Blockers

- None.

### Phase 3: Result Queries and Presenters

**Status:** Completed

#### Tasks Completed

- Added workspace alert, monitor history, exact run detail, and unresolved-alert queries with tenant
  scoping.
- Added explicit run counters for calls, observations, completion, evaluations, failures, model
  mismatches, tokens, latency, and alerts without an aggregate quality score.
- Added side-by-side pinned baseline/current provenance and mismatch reporting.
- Added UTF-8-safe bounded text, recursively bounded structured evidence, sensitive-key redaction,
  and provider-metadata allowlisting.
- Added a redacted diagnostic presenter that omits case inputs/context, prompts, outputs, and rule
  evidence while preserving operational IDs and counts.
- Replaced the operations context's temporary failed-run count with the formal unresolved-alert count.

#### Decisions Made

- Diagnostic maps are allowlisted and all browser-bound free text is UTF-8-safe and bounded.

#### Blockers

- None.

### Phase 4: Inertia Product Experience

**Status:** Completed

#### Tasks Completed

- Enabled the Alerts product navigation and added a workspace inbox ordered by unresolved state,
  severity, and recency.
- Added monitor results with formal unresolved alerts, explicit run counters, responsive history,
  missing-baseline guidance, and direct evidence links.
- Added run evidence with frozen prompts/configuration, case context, captured output, provider
  attempts, evaluations, rule results, baseline provenance, and separately labeled operational data.
- Added member acknowledgement, owner-only post-acknowledgement resolution, flash outcomes, and a
  redacted diagnostic download.
- Linked operations and active dashboard monitor cards to results, and replaced the temporary
  attention label with the formal unresolved-alert count.
- Added controller, authorization, cross-tenant, redaction, frontend state, inert-content, and
  responsive-layout tests.

#### Decisions Made

- Reused existing shadcn primitives and native disclosure elements; no dependency or UI primitive
  was added.
- All result routes stay inside the authenticated workspace scope because prompts, context, outputs,
  and alert evidence are private customer data.

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
- Completed Phase 2 with 33 focused alert-policy, lifecycle, capture, and scheduling tests passing.
- Completed Phase 3 with focused presenter, redaction, provenance, history, and workspace-scope tests.
- Completed Phase 4 with the full results/alerts Inertia slice and focused backend/frontend tests.

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
- `lib/silent_regression/run_results.ex`
- `lib/silent_regression/run_results/alert.ex`
- `lib/silent_regression/run_results/policy.ex`
- `lib/silent_regression/run_results/provenance.ex`
- `lib/silent_regression/captures/workers/observation_worker.ex`
- `priv/repo/migrations/20260916180822_create_result_alerts.exs`
- `test/silent_regression/run_results_test.exs`
- `test/silent_regression/run_results/policy_test.exs`
- `lib/silent_regression/run_results/presenter.ex`
- `lib/silent_regression/run_results/safe_value.ex`
- `lib/silent_regression/monitor_operations.ex`
- `test/silent_regression/run_results/presenter_test.exs`
- `test/silent_regression/run_results/safe_value_test.exs`
- `lib/silent_regression_web/controllers/run_result_controller.ex`
- `lib/silent_regression_web/controllers/result_alert_controller.ex`
- `lib/silent_regression_web/controllers/monitor_operations_controller.ex`
- `lib/silent_regression_web/router.ex`
- `assets/js/types/results.ts`
- `assets/js/components/result-evidence.tsx`
- `assets/js/components/product-shell.tsx`
- `assets/js/pages/Alerts/Index.tsx`
- `assets/js/pages/Monitors/Results.tsx`
- `assets/js/pages/Monitors/Run.tsx`
- `assets/js/pages/Monitors/Operations.tsx`
- `assets/js/pages/Dashboard.tsx`
- `test/silent_regression_web/controllers/run_result_controller_test.exs`
- `assets/js/test/pages/Alerts.test.tsx`
- `assets/js/test/pages/Results.test.tsx`
- `assets/js/test/pages/Run.test.tsx`

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
