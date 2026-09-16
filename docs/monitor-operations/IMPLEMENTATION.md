# Monitor Operations Implementation

## Phase 1 — Durable scheduling model

- Add monitor cadence, next/last scheduled timestamps, schedule actor, and pause reason.
- Add schema validation and database constraints.
- Expose a strong current-baseline compatibility check.
- Add operation-state queries and eligibility evaluation.
- Verify persistence, activation requirements, role boundaries, and next-run calculation.

## Phase 2 — Atomic orchestration and dispatcher

- Add owner-only configure, run-now, pause, and resume commands.
- Add idempotent due-slot dispatch and recurring Oban worker.
- Prevent overlapping capture runs at planning time.
- Add execution-time eligibility checks before provider-call reservation.
- Add automatic pause policies and the workspace daily call guardrail.
- Record lifecycle and scheduling audit events.
- Verify dispatch, multi-node safety, overlap, pause, invalidation, and guardrail behavior with
  controlled timestamps and no sleeps.

## Phase 3 — Operations experience

- Add authenticated workspace operations routes and controller actions.
- Add owner mutation controls and member read-only presentation.
- Add schedule, state, last/next run, and attention metrics.
- Update dashboard monitor routing and status presentation.
- Add controller and frontend interaction tests.

## Phase 4 — Integrated verification

- Exercise the fake-provider browser flow from approved baseline through activation, run-now, and
  pause.
- Run focused backend and frontend tests, asset compilation, formatting, and `mix precommit`.
- Update the private-alpha implementation plan and this progress log with completion evidence.
- Commit each completed slice independently.

