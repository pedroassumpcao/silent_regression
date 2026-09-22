# Guided monitor setup — progress

## Status: Stage 3 complete — Stage 4 next

- Research/history: [original setup research](RESEARCH.md), [UX assessment](UX_ASSESSMENT.md)
- Approved scope and acceptance criteria: [implementation plan](IMPLEMENTATION.md)
- Parent plan: [private alpha](../../plans/private_alpha_implementation_plan.md)

## Stage progress

| Stage | Status | Completed / pending |
| --- | --- | --- |
| 1. Honest saving and readiness | Complete | Saving, approval guards, manual readiness, copy, analytics and regressions verified |
| 2. Routing journey prototype | Implemented; founder direction accepted | Step 0, safe restart and practice/on-demand distinction addressed; independent research tracked in Stage 6 |
| 3. Common draft and routing recipe | Complete | Bounded workspace drafts, typed routing editors, combined reviewed proof and atomic handoff verified |
| 4. First run and manual completion | Not started | Coordinated authorization/review and value metrics pending |
| 5. Other recipes and guidance | Not started | JSON, sources, text and walkthrough pending |
| 6. Independent usability validation | Not started | Test script, external participants and findings pending |

## Architectural decisions

- 2026-09-21: Stage 3 uses a separate `guided_setup_drafts` table. Incomplete inputs do not become
  executable monitor versions. Drafts are workspace-scoped, bounded to 240 KB of raw input, versioned
  by recipe/schema, and protected by a revision comparison under a row lock. Stale tabs cannot rebase
  themselves silently. Whole-draft edits invalidate proof; partial explicit proof review is durable.
- 2026-09-21: Routing v1 supports 2–8 distinct normalized labels, 1–20 cases, ordered text messages
  or the existing bounded provider-native template format. Raw JSON remains text until validated.
  Variables come from the production renderer, and request previews come from the capture builder.
- 2026-09-21: Proof proposals run through both production evaluators. Confirmations preserve reviewer,
  timestamp, synthetic output, case/expectation/configuration fingerprints and evaluator version.
  Proposals alone never constitute review. Shared fixture judgments are copied only after explicit review.
- 2026-09-21: Handoff seals a new monitor/version/cases and reviewed shared-contract draft in one
  transaction, retaining immutable raw/review history. It does **not** approve the contract, execute a
  run, approve a reference, or activate scheduling. Existing owner-only approvals remain necessary;
  their integration is Stage 4. Existing monitors/successor drafts remain on their original path.
- 2026-09-21: Workspace purge includes the new drafts, and request logging filters the raw payload.
  The additive migration preserves all existing local data; no reset is needed.

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

### 2026-09-21 — Stage 3 completed

- Added durable routing drafts, production-backed request/proof compilation, reviewed atomic handoff,
  and a guided UI with one primary action per step. Dashboard shows resumable workspace drafts.
- Authoring routes use the existing authenticated workspace scope. None can authorize a provider call.
- Final `mix precommit`: **694 backend tests passed, 2 existing exclusions; 104 frontend tests**;
  TypeScript, formatting, dependency audit and asset build passed. `git diff --check` passed.
- Verified the browser journey on an isolated local server: request → incomplete example save/exit →
  dashboard resume → both production proof outcomes → partial review save/resume → first-run handoff
  screen. Exact request artifacts match allow/deny inputs. Heading focus and 390px layout checked;
  no horizontal document overflow. HTTP tests cover actual atomic sealing and duplicate submissions.
- Browser checks left one fictional, unsealed draft named `Stage 3 browser check — no calls` in the
  local workspace. Proof judgments on that draft are implementation-test activity, not partner research.
  No existing monitor was modified, no real contract approved, and no capture or schedule authorized.
- New request-log filtering requires restarting the user's Phoenix server. The temporary port-4001
  server had background jobs/plugins disabled and has been stopped; the user's server was not stopped.
- Navigation-time `MutationObserver.observe` console errors recurred without a source URL. No matching
  observer exists in application JS; cause remains unconfirmed. Do not claim a clean console or
  independent usability from this browser walkthrough. See the guide for details.
- Guidance explicitly distinguishes synthetic local proof from actual provider results and explains
  the temporary handoff to existing approval/run screens before Stage 4 integrates them.

### 2026-09-21 — Practice and execution terminology; Stage 3 authorized

- Founder accepted Step 0 but interpreted "manual mode" as simulated execution and wondered whether
  this preview prepares a real monitor. These are separate axes: practice vs real, on-demand vs scheduled.
- Changed completion to "Finish setup," clarified Run now can make paid provider calls in a real
  monitor, and explicitly stated that preview data never transfers into a real monitor. Final state
  says "Practice walkthrough complete," not real operational readiness.
- Founder authorized the clarification and continuation through the planned stages. Stage 3 begins
  with additive durable drafts; no data wipe, provider call or schedule activation is authorized here.
- Independent usability evidence remains outstanding, not implied by founder approval or automated tests.

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

### Stage 3

- `04ef5de`: preview terminology and accepted founder feedback.
- New backend/controller/compiler coverage: incomplete JSON, stale tabs, scope isolation, explicit
  partial/full review, changed expectations/requests, normalized label collisions, OpenAI/Anthropic
  request equivalence, member boundaries, revoked connections, zero-call/idempotent handoff,
  database-enforced sealed immutability and draft deletion with workspace purge.
- New frontend coverage: incomplete-input submission, message order, explicit expectations,
  shared/case evidence, partial review, conflict recovery and no-spend handoff.
- Guide: [GUIDED_SETUP.md](GUIDED_SETUP.md). The founder can resume or start a real routing draft after
  restarting Phoenix; provider authorization remains an explicit later action.

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
- Browser back/forward cannot be cancelled by Inertia's before-visit hook. Stage 3 now recovers bounded
  explicitly saved drafts (including invalid partial authoring); it does not promise background autosave
  or recovery of keystrokes that were never saved.
- The advanced template/rule/case UI remains available. Routing now has real guided authoring, while
  non-routing recipes and unified first-run/result completion remain Stages 5 and 4 respectively.
- Tab-local storage and local result simulation are disposable prototype boundaries, not reusable
  persistence/evaluation authority. Keep the production server-side guards and immutable audit history.
