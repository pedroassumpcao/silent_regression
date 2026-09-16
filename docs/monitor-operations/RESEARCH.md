# Monitor Operations Research

## Product boundary

Task 11 turns an approved baseline into a continuously operated monitor without expanding the
private-alpha scheduling surface beyond `Run now`, `Daily`, `Weekly`, `Pause`, and `Resume`.
The operation must remain understandable to a design partner: every run is durable, bounded, and
attributable; members may inspect it; only workspace owners may authorize provider spend or change
its lifecycle.

Task 12 owns the formal alert lifecycle. Until then, the operations page reports a durable
`runs_needing_attention` count derived from terminal capture runs. This avoids inventing a second
alert model that would immediately be replaced, while still surfacing failed, partially failed, or
review-required runs.

## Existing foundations

- Capture plans already freeze the exact monitor version, approved contract, credential, call cap,
  and observation set.
- Baseline captures already require an explicit authorization; manual and scheduled capture kinds
  already execute through the same worker path.
- Capture identity is already unique within a workspace.
- Credentials, contracts, baselines, and monitor versions already have durable compatibility and
  provenance fields.
- Oban already has separate `capture` and `scheduler` queues.

## Scheduling decisions

- Store cadence and `next_run_at` on the monitor because this is product state, not cron
  configuration.
- Use a one-minute Oban cron worker as a database-backed dispatcher. Static cron wakes the
  dispatcher; it does not encode each tenant's schedule.
- Daily and weekly schedules are fixed UTC intervals anchored at activation or schedule change.
- A delayed dispatcher skips missed intervals and advances to the first future slot. It does not
  create an unbounded catch-up storm.
- Scheduled identities use `scheduled:<monitor-id>:<intended-time>` so retries and multiple nodes
  converge on the same capture plan.
- Manual identities use a server-generated UUID.
- A monitor row lock serializes schedule decisions. Oban job uniqueness is additional queue
  hygiene, not the source of domain correctness.
- A new run is rejected while that monitor has a planned, queued, or running capture. The existing
  identity remains idempotent.
- `next_run_at` advances only in the same database transaction that decides whether a due slot was
  enqueued or intentionally skipped for overlap.

## Safety decisions

- Activation and resume require the exact current approved baseline to remain compatible with the
  active monitor version and approved contract.
- Provider credentials must be valid for the exact provider and requested model.
- A final execution-time eligibility check happens before reserving a provider attempt. This closes
  the race where a queued job starts after a monitor is paused or invalidated.
- The private alpha has a workspace daily provider-call guardrail. Planning uses the run's maximum
  possible calls, not only its planned calls, so retries cannot silently exceed the bound.
- Active monitors are automatically paused for revoked or invalid credentials, incompatible
  baselines/configuration, repeated authentication failures, a missing schedule owner, or exhausted
  workspace capacity.
- Pause cancels unfinished captures. Workers also observe cancellation before creating another
  provider-attempt ledger row.

## Concurrency model

PostgreSQL row locks provide the serialization boundary. The dispatcher claims due monitors with
`FOR UPDATE SKIP LOCKED`, then rechecks all state under the lock. A workspace lock precedes the
monitor lock whenever the daily guardrail is involved, giving all scheduling paths a stable lock
order. Capture planning keeps its monitor lock and adds the overlap check before insertion.

Oban uniqueness is insertion-time uniqueness and does not prevent two already-running jobs from
executing concurrently, so it is not relied upon for schedule correctness.

## UI decisions

- Add an authenticated workspace route at `/app/:workspace_slug/monitors/:monitor_id/operations`.
  The existing `:workspace_scope` pipeline supplies the tenant scope and role.
- Owners see cadence controls, a bounded-spend confirmation for `Run now`, and pause/resume
  actions.
- Members see the same durable state and timestamps but no mutation controls.
- The page shows state, cadence, last run, next UTC run, and runs needing attention.
- The dashboard routes approved `baseline_pending`, active, and paused monitors to operations;
  other completed monitors continue to their contract or baseline step as appropriate.

## Primary references

- Oban 2.24 cron configuration and job uniqueness documentation.
- PostgreSQL row-level locking and `SKIP LOCKED` documentation.
- Existing Silent Regression capture, baseline, credential, audit, and Inertia/shadcn patterns.

