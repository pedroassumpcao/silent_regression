# Run Results and Alerts Research

## Overview

Task 12 turns durable capture evidence into an inspectable monitoring result. It adds monitor run
history, per-run evidence, and a formal alert lifecycle without weakening the deterministic-only
product boundary. A contract failure may be described as a contract failure; provider, model,
latency, usage, provenance, and evaluator problems remain operational anomalies and are never
described as content degradation.

## Problem Statement

Tasks 9–11 already preserve the evidence needed to explain a run, but the product has no formal
result surface or alert record. The operations page therefore uses a temporary count of failed or
review-required runs. Users need to answer four questions without reading database rows:

1. Did the exact approved workflow run against its exact baseline?
2. Which calls completed, failed, or had an unknown outcome?
3. Which deterministic rules passed or failed, and what bounded evidence explains each outcome?
4. What needs action, why, and who acknowledged or resolved it?

## User Stories / Use Cases

- A member opens a monitor and sees its immutable run history without being able to authorize
  provider spend.
- A reviewer opens a run and traces a content alert through the failed contract evaluation, rule
  results, output, case, and exact baseline/current provenance.
- An owner sees an authentication or model anomaly clearly separated from deterministic failures.
- A member acknowledges an alert to show it has been seen; an owner resolves it after action.
- A retried worker or reloaded result page cannot create a duplicate alert.
- A long or adversarial prompt, context, output, failure message, or evidence value remains inert
  text and cannot break the page layout.

## Technical Research

### Approach Options

#### Derive alerts on every page load

This keeps storage small, but acknowledgement and resolution have no stable identity. It also makes
deduplication and future notifications fragile. Rejected.

#### Emit one alert for every failed rule and every observation anomaly

This maximizes granularity but can flood a monitor when a composite rule or provider incident affects
many samples. It also misrepresents failed `any` groups as several independently required rules.
Rejected.

#### Persist one content alert per failed evaluation and grouped operational alerts per run

A content alert points to one exact evaluation and derives its severity from the decisive failing
rules. Operational alerts group the same finding code within a run and retain bounded affected
observation IDs. The immutable run detail remains the complete evidence source. Selected.

### Recommended Approach

1. Add an optional `severity` of `critical` or `warning` to every contract rule. Omission remains
   backward compatible and means `critical`; existing normalized contract bytes and fingerprints do
   not change.
2. Persist the chosen severity on immutable rule results.
3. Pin each new manual or scheduled run to the approved baseline snapshot available at planning
   time. Historical runs without this link remain visible but cannot produce baseline comparisons.
4. Create one durable alert per actionable finding identity. Enforce uniqueness in PostgreSQL and
   use conflict-safe inserts so worker retries are harmless.
5. Run alert synchronization after each observation worker completion. Non-terminal runs are a
   no-op; the final worker creates alerts. A retry calls the same idempotent synchronizer.
6. Separate `contract_failure` from `operational_anomaly` in both data and language.
7. Compare latency and usage only when exact provenance matches. Use conservative, explicit alpha
   warning thresholds rather than presenting an unexplained score.
8. Render customer/provider content only as React text. Never use `dangerouslySetInnerHTML`.
   Truncate browser payloads at documented UTF-8-safe bounds while retaining the immutable database
   evidence.

PostgreSQL unique constraints and indexes provide the concurrency boundary rather than an
application-level check-then-insert race. Ecto translates those database constraint failures into
changeset errors when needed.

### Explicit Alpha Alert Policy

| Finding | Category | Severity | Identity |
| --- | --- | --- | --- |
| Deterministic evaluation failed | Contract failure | Highest decisive failed-rule severity | Run + evaluation |
| Evaluator error | Operational anomaly | Critical | Run + evaluator error |
| Authentication, authorization, invalid request, oversized request, malformed response, credential unavailable, call-cap exhaustion, unknown outcome | Operational anomaly | Critical | Run + failure category |
| Rate limit, timeout, transport, provider unavailable | Operational anomaly | Warning | Run + failure category |
| Returned model differs from requested model | Operational anomaly | Critical | Run + model mismatch |
| Completion is incomplete or unknown | Operational anomaly | Critical | Run + completion state |
| Current latency is greater than both 3× the baseline case maximum and 2,000 ms above it | Operational anomaly | Warning | Run + latency |
| Current total tokens are greater than both 2× the baseline case maximum and 100 tokens above it | Operational anomaly | Warning | Run + usage |
| Baseline is missing or provenance differs | Operational anomaly | Critical | Run + provenance; skip baseline-relative findings |

The latency and usage rules are intentionally conservative alpha heuristics. The UI displays their
reference, observed value, multiplier, and absolute-delta requirement. They are not quality scores.

### Decisive Rule Severity

- A failed `all` group delegates to its failed children, because each child is required.
- A failed `any` group is decisive as a group, because no individual alternative was independently
  required.
- A failed `not` group is decisive as a group.
- A failed leaf is decisive itself.
- Any critical decisive failure makes the evaluation alert critical; otherwise it is warning.

### Alert Lifecycle and Authorization

- `open -> acknowledged -> resolved` is forward-only.
- Any workspace owner or member may acknowledge an alert. Acknowledgement records the exact actor
  and timestamp but does not approve or alter evidence.
- Only a workspace owner may resolve an alert.
- Task 13 will add append-only review classifications and governance. It will not retroactively turn
  Task 12 acknowledgement into a judgment.

## Data Requirements

### Capture provenance

`capture_runs.baseline_snapshot_id` is nullable for baseline and historical runs. New manual and
scheduled runs pin the compatible approved snapshot when one exists. The ID becomes part of the
immutable run plan.

### Rule results

`capture_rule_results.severity` stores `critical` or `warning` and defaults to `critical` for old and
severity-omitting contracts.

### Alerts

An alert stores workspace, monitor, run, optional evaluation, identity key, category, severity,
code, title, explanation, bounded evidence, lifecycle timestamps/actors, and notification state.
The unique `(workspace_id, identity_key)` database index is the final idempotency guarantee.

## UI/UX Considerations

- Workspace alert inbox: unresolved alerts first, with category, severity, monitor, run, state, and
  direct evidence link.
- Monitor results page: provenance health, explicit counts, run history, and monitor-scoped alerts.
- Run detail: baseline/current provenance side by side; plain operational and deterministic
  summaries; one card per case/sample; observation, attempts, output, evaluation, and all rule
  results.
- No aggregate “quality score.” Counts always expose their denominator.
- Empty, in-progress, partial, stale, and no-alert states need plain-language next steps.
- Evidence blocks use bounded scroll regions, wrapping, preserved whitespace, and text rendering.
- Mutation feedback uses ordinary page/flash status semantics; it must not turn every passive alert
  card into an assertive screen-reader announcement.

## Integration Points

- `SilentRegression.Captures` pins baseline provenance and persists rule severity.
- `SilentRegression.Captures.Workers.ObservationWorker` invokes idempotent alert sync.
- A new `SilentRegression.RunResults` context owns alert generation, lifecycle, queries, and safe
  presenters.
- Authenticated Inertia controller routes live inside the existing workspace scope because prompt,
  context, output, provider evidence, and alert state are private tenant data.
- The operations page replaces its temporary attention count with formal unresolved alerts.
- Task 13 consumes exact alert/evaluation/rule identities for structured reviews.
- Task 14 consumes notification state for deduplicated email delivery.

## Risks and Challenges

- **Alert floods:** group run-level operational findings and use one content alert per evaluation.
- **False operational warnings:** use conservative baseline-relative thresholds and label them as
  operational warnings, not degradation.
- **Stale comparisons:** refuse latency/usage comparisons when pinned provenance is absent or
  mismatched.
- **Race conditions:** use a database unique index plus conflict-safe insert, not a prior existence
  check.
- **Sensitive data:** retain raw customer content only in the already-authorized evidence tables;
  diagnostic maps use strict allowlists and browser values are bounded.
- **XSS/layout failure:** rely on React's text escaping, avoid HTML escape hatches, and constrain
  long blocks in CSS.
- **Task overlap:** Task 12 owns mechanical lifecycle state; Task 13 owns human classification,
  rationale, supersession, and correction workflows.

## Open Questions Deferred Beyond Task 12

- Calibrate latency and usage thresholds from private-alpha history rather than the explicit starter
  policy.
- Decide retention and deletion rules for raw prompt/context/output evidence in Task 14.
- Decide email provider and notification preferences in Task 14.
- Decide whether resolved alerts can be reopened by a later append-only review in Task 13.

## References

- PostgreSQL unique constraints and partial indexes: https://www.postgresql.org/docs/16/ddl-constraints.html
- Ecto constraints and upserts: https://ecto.hexdocs.pm/constraints-and-upserts.html
- OWASP cross-site scripting prevention: https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html
- W3C status-message guidance: https://www.w3.org/WAI/WCAG21/Understanding/status-messages

