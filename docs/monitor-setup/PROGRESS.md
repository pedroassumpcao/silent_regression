# Guided monitor setup — progress

## Status: Stage 1 — In progress

- Research/history: [original setup research](RESEARCH.md), [UX assessment](UX_ASSESSMENT.md)
- Approved scope and acceptance criteria: [implementation plan](IMPLEMENTATION.md)
- Parent plan: [private alpha](../../plans/private_alpha_implementation_plan.md)

## Stage progress

| Stage | Status | Completed / pending |
| --- | --- | --- |
| 1. Honest saving and readiness | In progress | Source audit complete; code/tests pending |
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

## Session log

### 2026-09-21 — Scope approved and implementation started

- Founder approved the staged redesign and permits local-data reset if needed.
- Read the build/shadcn workflows and prior assessment; inspected saving, approval, and readiness paths.
- Added the staged implementation plan and this durable history/progress log.
- Existing verification issue to resolve: UTC-reset scheduling test mixes fixed dates with current-time
  capture fixtures. Cause is under investigation; no scheduling behavior change assumed.
- No provider calls, database reset, deployment, or external invitation performed.

## Verification and commits

Pending Stage 1 implementation and `mix precommit`.

## Files changed

- `docs/monitor-setup/IMPLEMENTATION.md`, `PROGRESS.md`: new scoped roadmap and progress history.
- `docs/monitor-setup/RESEARCH.md`, `plans/private_alpha_implementation_plan.md`: links to approved follow-up.

## Lessons learned / remaining risks

- A button labeled Save must submit the actual current editor values, not only record navigation.
- Human usability validation remains separate from correctness tests and requires unfamiliar users.
