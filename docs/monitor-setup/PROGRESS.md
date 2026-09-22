# Guided monitor setup — progress

## Status: Stage 2 implemented — founder feedback revision ready for review

- Research/history: [original setup research](RESEARCH.md), [UX assessment](UX_ASSESSMENT.md)
- Approved scope and acceptance criteria: [implementation plan](IMPLEMENTATION.md)
- Parent plan: [private alpha](../../plans/private_alpha_implementation_plan.md)

## Stage progress

| Stage | Status | Completed / pending |
| --- | --- | --- |
| 1. Honest saving and readiness | Complete | Saving, approval guards, manual readiness, copy, analytics and regressions verified |
| 2. Routing journey prototype | Implemented; review in progress | Initial feedback implemented: explicit Step 0 and safe restart; revised interaction confirmation and unfamiliar-user feedback pending |
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

### 2026-09-21 — Founder feedback: scenario selection belongs in Step 0

- Founder finds the staged journey easier to understand, but scenario selection during later steps
  makes the reset surprising. Requested an explicit Step 0 before the five-step journey.
- Implemented: choose output shape/scenario before starting; later changes use a separate
  restart screen with reset scope explained. Keep the current draft/history until replacement is
  explicitly started, and provide a cancel path. No production behavior or route changes.
- Existing saved previews resume unchanged. A simulated upstream fix records recovery without changing
  the scenario identity. Added five component regressions for selection, cancellation, replacement,
  storage failure and backwards-compatible draft recovery, plus a model assertion for scenario identity.
- Verified browser selection → Step 2 → cancel/recover → explicit restart at Step 1. The asset rebuild
  reloaded the test tab mid-check; resumed from its saved state and repeated the restart successfully.
- Final `mix precommit`: **679 backend tests passed, 2 existing exclusions; 99 frontend tests passed**;
  TypeScript, audit, formatting and asset build passed. No provider calls or database changes.

### 2026-09-21 — Stage 2 implementation and technical verification complete

- Added the read-only authenticated-workspace `setup-preview` route and separate React prototype.
  Production setup screens, domain engines, credentials, real permissions and records are unchanged.
- Built the routing journey and JSON decision-field comparison using existing shadcn components;
  one primary CTA per stage, contextual guidance, heading focus and responsive progress/evidence.
- Both positive and negative proof examples show shared and case results independently. Explicit
  reviewer confirmation is required. Expectation changes clear proof/finish state; fixed proposed
  judgments cannot silently be rewritten by the simulation to agree with a mistaken expectation.
- Wrong output, wrong expectation, provider failure and member-to-owner simulation have distinct
  recovery paths. Each retry requires fresh authorization; bounded tab history retains failed evidence.
- Save/return includes incomplete text and partial proof judgments, handles denied storage honestly,
  namespaces storage by user/workspace and checks restored shape/review identity. This is deliberately
  tab-local prototype storage, not the server-backed draft architecture planned for Stage 3.
- Added [PROTOTYPE.md](PROTOTYPE.md): entry URL, review instructions, scenario matrix, architecture
  comparison, non-enum JSON stress case, production boundaries and an unfamiliar-user interview script.
- Browser walkthrough completed in an isolated in-app tab for routing and JSON failure/retry, with
  blank-input reload recovery and desktop/mobile checks. One earlier sign-in/navigation observer error
  did not recur; full caveat recorded in PROTOTYPE.md. This is not independent usability evidence.
- No schema change/reset, live provider call, real monitor mutation or external communication.
  Normal local development-mailbox login created only its usual session/audit records.
- Founder review is next. Stage 3 is not started; unfamiliar-user feedback remains pending availability.

### 2026-09-21 — Stage 2 started

- Founder requested Stage 2. Building a separate authenticated-workspace preview, not replacing the
  production setup or implementing the Stage 3 draft schema early.
- Prototype uses mock inputs/results and tab-local storage only. No credentials, provider calls,
  monitor mutations, database reset, or permission changes are needed.
- Apply onboarding guidance (one next action and first understood result), existing shadcn primitives,
  and explicit progress/focus handling. Independent usability evidence remains outstanding.

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

### Stage 2

- `mix precommit`: dependency advisory audit clean; **679 backend tests passed, 2 existing private-
  artifact exclusions**; TypeScript passed; **94 frontend tests across 16 files**; assets built.
  `git diff --check` passed. New coverage adds 3 controller tests and 18 model/component tests.
- Browser details and human-research boundaries: [PROTOTYPE.md](PROTOTYPE.md).
- Implementation commit: `7184381` — isolated prototype, shared routing/JSON journey, recovery and tests.
- Files: `SetupPreviewController`, authenticated preview GET, `SetupPreview.tsx`, isolated
  `setup-preview.ts` model, corresponding tests, this track's documents and parent-plan status.

### Stage 1

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
- The complex production template/rule/case UI is intentionally still present. Stage 2 is a separate
  zero-call prototype ready for feedback, not delivery of Stage 3's production authoring architecture.
- Tab-local storage and local result simulation are disposable prototype boundaries, not reusable
  persistence/evaluation authority. Keep the production server-side guards and immutable audit history.
