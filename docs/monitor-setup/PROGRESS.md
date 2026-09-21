# Guided monitor setup — progress

## Status: Stage 1 complete — Stage 2 next

- Research/history: [original setup research](RESEARCH.md), [UX assessment](UX_ASSESSMENT.md)
- Approved scope and acceptance criteria: [implementation plan](IMPLEMENTATION.md)
- Parent plan: [private alpha](../../plans/private_alpha_implementation_plan.md)

## Stage progress

| Stage | Status | Completed / pending |
| --- | --- | --- |
| 1. Honest saving and readiness | Complete | Saving, approval guards, manual readiness, copy, analytics and regressions verified |
| 2. Routing journey prototype | Not started | Prototype and feedback pending |
| 3. Common draft and routing recipe | Not started | Draft model, typed editors, combined proof pending |
| 4. First run and manual completion | Not started | Coordinated authorization/review and value metrics pending |
| 5. Other recipes and guidance | Not started | JSON, sources, text and walkthrough pending |
| 6. Independent usability validation | Not started | Test script, external participants and findings pending |

## Architectural decisions

- 2026-09-21: Retain the assessment as historical evidence; add a separate implementation/progress
  track rather than rewriting completed alpha tasks. Work one stage at a time with focused commits.
- 2026-09-21: Do not wipe local data for the immediate fixes. Stage 1 saves valid current forms and
  stays on invalid forms; durable incomplete-input storage is an explicit Stage 3 deliverable.
- 2026-09-21: Browser dirty-state protection complements, not replaces, server-side approval identity
  checks under the existing transaction locks.
- 2026-09-21: Preserve exact provider requests, independent expectation/proof review, owner approval,
  bounded execution, compatibility checks, and immutable history throughout the redesign.
- 2026-09-21: Add only an event-name constraint migration in Stage 1. `monitor.activated` records all
  modes; existing `schedule.activated` retains its recurring-only meaning. Rollback preserves existing
  events while enforcing the previous name allowlist for new writes. Do not fabricate a backfill for
  past manual readiness; broader first-value timestamps remain Stage 4 work.
- 2026-09-21: No new routes or authentication exceptions. Setup updates and approval remain in the
  `/app/:workspace_slug` scope with `:browser`, `:authenticated`, and `:workspace_scope`. Owner-only
  approval and separate recent-authentication/provider-spend boundaries remain unchanged.

## Session log

### 2026-09-21 — Scope approved and implementation started

- Founder approved the staged redesign and permits local-data reset if needed.
- Read the build/shadcn workflows and prior assessment; inspected saving, approval, and readiness paths.
- Added the staged implementation plan and this durable history/progress log.
- Existing verification issue to resolve: UTC-reset scheduling test mixes fixed dates with current-time
  capture fixtures. Cause is under investigation; no scheduling behavior change assumed.
- No provider calls, database reset, deployment, or external invitation performed.

### 2026-09-21 — Stage 1 completed

- Save and exit now submits the active purpose, connection, request, cases, or import form through
  the normal validation/persistence action. It redirects to monitors only after success. Validation
  errors clear stale success messages and retain current editor text; partial invalid input is not
  yet durable across leaving/reload. Fixed a blank-name/description trimming crash found by tests.
- Removed the automatic-save promise, added explicit saved/unsaved status, link/unload warnings and
  confirmation before discarding edits on manual/import switching. Configuration locking now clearly
  continues to checks instead of calling the entire journey finished.
- Rule, example, waiver and invalid raw-JSON edits block approval. Unsaved rules block local proof
  mutation; unsaved proof edits block rule editing. Approval submits the exact contract ID, combined
  fingerprint and proof fingerprint; the server verifies them under the existing monitor lock.
  Visible rule editors refresh when saved semantics change, so old form defaults cannot masquerade
  as the newly returned server revision. Cancelling fixture edits actually resets their values.
- Active manual monitors now complete the readiness checklist. Recurrence is separate; opening a
  successor draft no longer causes a multiple-setup query error or hides the active configuration.
- Historical rescore copy no longer claims a reference replacement is still outstanding. Completed
  captures say ready for review, not inspected. Latest managed run links to its evidence instead of
  unfinished-task copy. Explicit setup exits are no longer called abandonment.
- Diagnosed the prior scheduling failure: fixed simulated dates conflicted with real fixture capture
  timestamps. Aligned the simulated UTC day with fixture creation and retained the original slot/reset
  assertions. No production scheduling/capacity algorithm was changed for that test correction.
- Applied the additive migration to local development and test databases; retained all local data.
- Browser verification was attempted but no complete new walkthrough was obtained: the local server
  was initially stopped and the active browser session changed during the check. A temporary server
  ran with Oban queues/plugins disabled, then was stopped. Do not count this as independent usability
  evidence or a completed browser smoke; use an isolated session during Stage 2.

## Verification and commits

- Final `mix precommit`: dependency advisory audit clean; **676 backend tests passed, 2 existing
  private-artifact exclusions**; TypeScript passed; **76 frontend tests passed across 14 files**;
  production assets built. `git diff --check` passed.
- Focused coverage includes all five editable save paths, incomplete import retention, navigation
  warnings, blank-name validation, stale/missing/wrong approval identities, changed proof fixtures,
  invalid visible JSON, fixture cancellation, refreshed rule fields, manual readiness and successors.
- No live provider requests or provider credential validation performed.

| Commit | Change |
| --- | --- |
| `478e6ec` | Approved roadmap, research links, history/progress tracker |
| `92615d8` | Actual save-and-exit, navigation/validation and accurate configuration finish |
| `40c970c` | Unsaved-edit protection and approval bound to the reviewed saved revision |
| `61a3784` | Manual readiness, separate recurring metrics, progress/evidence copy and migration |
| `43697d4` | Date-independent UTC capacity-reset regression |

## Files changed

- `docs/monitor-setup/IMPLEMENTATION.md`, `PROGRESS.md`: new scoped roadmap and progress history.
- `docs/monitor-setup/RESEARCH.md`, `plans/private_alpha_implementation_plan.md`: links to approved follow-up.
- `assets/js/pages/Monitors/{Setup,Contract,Baseline,Operations}.tsx`: corrected interaction and copy.
- `assets/js/hooks/{use-unsaved-changes.ts,use-draft-editors.tsx}`: local editor coordination/guards.
- Corresponding component/controller tests plus `pilot_readiness_test.exs` and scheduling regression.
- Setup/contract controllers, ContractAuthoring, Monitor metadata validation, PilotReadiness,
  MonitorOperations, ProductAnalytics and the manual-readiness event constraint migration.

## Lessons learned / remaining risks

- A button labeled Save must submit the actual current editor values, not only record navigation.
- Human usability validation remains separate from correctness tests and requires unfamiliar users.
- Browser back/forward cannot be cancelled by Inertia's before-visit hook; Stage 3 must recover bounded
  drafts rather than relying only on warnings. Invalid partial authoring remains in memory for now.
- The complex template/rule/case UI is intentionally still present: Stage 1 is a trust/correctness
  patch, not completion of the guided redesign. Stage 2 is the zero-call routing prototype and JSON check.
