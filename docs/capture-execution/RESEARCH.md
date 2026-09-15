# Durable Capture Execution and Provider Accounting Research

## Overview

Task 9 replaces the spike's CLI-only, in-memory runner with a PostgreSQL-backed execution path for
baseline, manual, and future scheduled captures. It owns execution durability, provider-call
accounting, immutable observations, and persisted deterministic evaluations. Task 10 will add the
customer-facing baseline preflight, spend authorization, progress, and approval flow; Task 11 will
add the recurring dispatcher.

## Product boundary

The private alpha calls providers on a customer's behalf. That makes every retry a potentially
billable action and makes ambiguous network outcomes materially different from ordinary background
job failures. The system must never imply exactly-once provider execution when the provider does not
offer an idempotent completion boundary.

All capture entry points use the same path:

1. Create or find a run by an immutable caller-supplied identity.
2. Snapshot the exact monitor version, approved contract, credential identity, active cases, sample
   count, retry policy, and hard call cap.
3. Insert one planned observation per case/sample pair.
4. Enqueue one unique capture job per planned observation.
5. Reserve a provider-attempt row under a run lock before any network request.
6. Resolve the encrypted credential only inside the worker, perform exactly one provider request,
   and persist its bounded result.
7. Evaluate successful output locally under the snapshotted approved contract.
8. Finalize the run honestly as succeeded, partially failed, failed, cancelled, or requiring review
   because an attempt outcome is unknown.

## Selected technical approach

### Oban with manual test mode

Use the current stable Oban 2.24 series with PostgreSQL. Configure a bounded `capture` queue and a
single-concurrency `scheduler` queue now; Task 11 will add the recurring dispatcher. Tests use
Oban's `:manual` mode so job insertion and execution remain explicit and compatible with the Ecto
sandbox.

The application uses Oban's supported migration API and starts Oban under the existing application
supervisor after the repository. Job arguments contain identifiers only—never credentials, prompt
bytes, contexts, outputs, or contract contents.

### Database identity before Oban uniqueness

Oban uniqueness prevents ordinary duplicate enqueues but applies only at insertion time. Correctness
also needs database constraints:

- a run identity is unique within a workspace;
- a planned observation is unique by run, case version, and sample index;
- a provider attempt is unique by observation and attempt number;
- an evaluation is unique by observation, contract version, and evaluator engine version;
- a rule result is unique by evaluation and rule ID.

Workers are idempotent against those records. Oban uniqueness is an additional queue-level guard,
not the source of truth.

### Ledger-first call accounting

Before network I/O, a worker locks the run and observation, counts existing provider-attempt rows,
checks cancellation and the run's maximum-call cap, and inserts a `started` attempt with a stable
client request ID. That insert is the accounting event. A retry is a new row and therefore consumes
one more unit of the cap.

After a known provider result, the worker atomically marks the attempt succeeded or failed and
stores the observation result. A retryable known failure may enqueue or schedule another execution
only when budget remains.

If a worker restarts and finds a `started` attempt without a terminal result, it does not blindly
repeat the request. The attempt and observation become `unknown`, and the run becomes an honest
review-required terminal result. This avoids silent duplicate spend after the classic
"provider accepted the request, process died before persistence" window.

OpenAI accepts an `X-Client-Request-Id` for troubleshooting, which improves reconciliation but is
not documented as an idempotency guarantee. Provider request IDs and the client request ID are safe,
bounded provenance. Anthropic's response request ID is retained similarly. Neither identifier is
treated as proof that replay is safe.

### One provider attempt per adapter call

The product provider boundary performs exactly one HTTP request with Req's internal retry disabled.
The durable worker, not Req and not the adapter, owns retry policy. This makes every attempted call
visible to the database budget before it happens.

Adapters return one bounded provider-neutral result:

- requested and returned model;
- output text;
- complete, incomplete, or unknown completion state;
- input and output token counts;
- latency and captured timestamp;
- safe provider request ID and stable client request ID;
- finish reason and a small normalized metadata map;
- or a categorized, retryable/non-retryable failure.

Raw provider response bodies are not persisted. Credentials are loaded by workspace and credential
ID immediately before execution and never enter Oban arguments or logs.

### Immutable evidence and rescorable interpretation

`capture_observations` stores the immutable provider result or bounded terminal failure. Successful
observations are evaluated locally using the exact approved contract version and evaluator engine
recorded on the run. Evaluations and rule results are separate append-only rows so future rescoring
does not rewrite provider evidence.

Database triggers reject mutation of terminal observation evidence, provider attempts, evaluations,
and rule results. Run lifecycle fields and aggregate timestamps may advance, but immutable run-plan
references and limits cannot change after insertion.

### Cancellation and finalization

Cancellation is cooperative and durable:

- the run records `cancellation_requested_at`;
- pending observations become cancelled before any call;
- queued jobs are cancelled where possible;
- an already executing provider request may finish, and its result is retained;
- no subsequent retry is scheduled after cancellation.

Run finalization is derived from observation states. Partial provider failure is never collapsed into
success, and completed observations survive cancellation or failure.

## Data model

### `capture_runs`

Stores workspace, monitor, monitor version, approved contract version, provider credential, creator,
run kind, caller identity, provider/model snapshot, configuration and case-set fingerprints,
evaluator version, sample count, retry policy, planned calls, maximum calls, lifecycle status, and
timestamps.

### `capture_observations`

Stores the planned case/sample identity and terminal provider evidence: status, output, model
provenance, completion state, usage, latency, request identity, failure category/message, and
captured timestamp.

### `provider_attempts`

The append-only spend ledger. Each row represents one reserved network attempt with its attempt
number, stable client request ID, status, retryability, provider request ID, latency, and bounded
failure provenance.

### `capture_evaluations` and `capture_rule_results`

Persist the deterministic Task 7 evaluation under an exact contract and engine version. Evidence is
bounded by the evaluator and stored separately from the observation.

## Failure taxonomy

Persist stable internal categories rather than provider prose: authentication, authorization,
rate-limited, invalid request, request too large, timeout, transport, provider unavailable,
malformed response, model mismatch, and unknown outcome. Retry only rate limiting, timeouts,
selected transport failures, and provider-unavailable failures. Authentication, authorization,
invalid request, malformed response, and model mismatch are terminal.

## Implementation phases

1. Add Oban, its supported migration, bounded queues, supervision, and manual test configuration.
2. Add the durable capture schemas, database constraints, indexes, and immutability guards.
3. Add the one-attempt product provider contract and direct Req adapters for OpenAI and Anthropic.
4. Add run planning, unique enqueueing, workers, call reservation, retries, cancellation,
   evaluation persistence, and finalization.
5. Add worker and accounting tests for duplicates, caps, retries, cancellation, restart ambiguity,
   partial failure, provenance, and tenant isolation; then run the full precommit gate.

Each phase receives its own focused commit. The private-alpha implementation plan remains the single
progress tracker.

## Deferred boundaries

- Baseline preflight, explicit spend authorization, and progress UI belong to Task 10.
- Recurring scheduling and due-monitor claiming belong to Task 11; Task 9 only provides the shared
  scheduled run kind and queue.
- Result browsing, alerting, and operational presentation belong to Task 12.
- Workspace-wide quotas and production operational hardening belong to Task 14.
- ReqLLM remains deferred until this normalized boundary can be compared without weakening attempt
  accounting, provenance, or testability.

## References

- [Oban installation](https://oban.hexdocs.pm/installation.html)
- [Oban unique jobs](https://oban.hexdocs.pm/unique_jobs.html)
- [Oban testing](https://hexdocs.pm/oban/testing.html)
- [Oban testing helpers](https://oban.hexdocs.pm/Oban.Testing.html)
- [OpenAI request IDs](https://platform.openai.com/docs/api-reference/backward-compatibility)
- [Productization plan](../../plans/productization_plan.md)
- [Private-alpha implementation plan](../../plans/private_alpha_implementation_plan.md)
