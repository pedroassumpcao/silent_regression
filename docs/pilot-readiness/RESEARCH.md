# Pilot Readiness Research

## Overview

Task 14 turns the completed private-alpha product loop into a controlled external-pilot boundary.
It does not deploy the application, add billing, open registration, or replace deterministic
monitoring with a semantic judge.

The repository already has useful foundations: invite-only authentication, workspace isolation,
encrypted and revocable provider credentials, resumable monitor setup, append-only content-free
product events, bounded captures, a daily workspace call envelope, durable Oban jobs, immutable
evidence, structured review, and local/test Swoosh adapters.

## Product Questions This Task Must Answer

- Where did an invited partner stop before activating a useful monitor?
- Did the partner require founder help, and at which bounded setup stage?
- Did an actionable alert lead to a review and a concrete follow-up?
- Can email notify the right workspace members once without disclosing customer content?
- Can the application stop abusive or accidental spend before a provider request?
- Can an operator close and delete a workspace in the correct evidence-safe order?
- Can credentials and backups be recovered or rotated without silently losing decryptability?

## Existing Foundations and Gaps

### Existing

- `SilentRegression.ProductAnalytics` stores append-only, allowlisted setup events whose properties
  are bounded enums and counts.
- Dashboard, setup, contract, baseline, operations, results, alerts, and review screens already
  expose the complete private-alpha loop.
- `Swoosh.Adapters.Local` is configured outside tests and `Swoosh.Adapters.Test` is configured in
  tests.
- Oban jobs contain record identifiers rather than prompts, contexts, outputs, or credentials.
- Provider models and behavior-affecting request parameters are allowlisted.
- Each run has a hard maximum provider-call count, and scheduled/manual operations reserve against
  a 200-call daily workspace envelope.
- Credentials use Cloak AES-256-GCM, are never returned to the browser, and have an explicit
  revocation lifecycle.

### Missing

- The product does not derive one six-stage activation checklist spanning credential through
  schedule activation.
- Product events stop at monitor setup and do not yet cover contract, baseline, scheduling, review,
  corrective action, or founder assistance.
- Result alerts have notification state but no recipient preferences, durable delivery record, or
  mail worker.
- There is no daily workspace run-count cap and limits are configuration-wide rather than explicit
  pilot policy.
- Sensitive endpoints do not have durable cross-node rate limits.
- `closed` workspace state has no governed transition or ordered purge operation.
- Production encryption accepts only one key, so it cannot perform a zero-downtime key rotation.
- Backup/restore, incident response, deletion, and pilot-support procedures are undocumented.

## Recommended Architecture

### Derived activation checklist

Derive each item from authoritative domain state rather than persisting mutable completion flags:

1. Credential: at least one valid, non-revoked provider credential.
2. Workflow: a completed setup with an active monitor version.
3. Cases: the active version has at least one active case.
4. Contract: the monitor has an approved compatible deterministic contract.
5. Baseline: the monitor has an approved compatible baseline.
6. Schedule: the monitor is active with a daily or weekly schedule.

The checklist should select the most advanced monitor in a workspace, preserve per-step links, and
remain truthful after credential revocation, contract revision, or schedule pause.

### First-party product learning events

Extend the existing append-only PostgreSQL event stream rather than introducing GA, PostHog, or a
client-side analytics SDK for the invite-only alpha. Every event must answer an explicit product
decision and accept only schema-checked enums, booleans, counts, durations, and record identifiers.
Prompts, contexts, outputs, rule text, rationale, credentials, emails, names, URLs, IP addresses,
user agents, and arbitrary strings are forbidden.

Recommended event families:

- activation progress and first-monitor activation;
- setup abandonment;
- founder assistance by allowlisted stage and reason;
- baseline approval;
- schedule activation;
- alert review classification and action;
- corrective action started.

Time-to-first-monitor should be derived from invitation acceptance and first schedule activation,
not trusted as a browser-supplied duration.

### Actionable-alert email

Use a database notification outbox keyed by alert, recipient, and channel. Insert delivery rows in
the same transaction that synchronizes an actionable alert, then enqueue an Oban worker containing
only the delivery ID. A workspace/user preference controls whether a row is created. Email content
contains only monitor name, alert category/severity, and an authenticated link; it never contains
prompts, contexts, outputs, rule evidence, or review rationale.

Keep `Swoosh.Adapters.Local` until a provider is selected. Oban uniqueness reduces duplicate work,
while a database uniqueness constraint is the authoritative deduplication boundary. No generic
email provider can guarantee exactly-once delivery across a process crash after the provider accepts
the message but before the local transaction records success; the runbook must acknowledge this
small retry edge.

### Durable rate limiting

Use PostgreSQL fixed-window buckets with hashed subjects and atomic `INSERT ... ON CONFLICT DO
UPDATE`. This works across multiple Phoenix instances without adding Redis. Store only an HMAC of
the subject, never raw email, token, IP address, or credential. Protect login, invitation acceptance,
credential validation, baseline authorization, schedule activation, and Run now.

Rate limiting supplements rather than replaces CSRF protection, authentication, owner checks,
provider-call reservations, and workspace spend caps.

### Pilot limits

Represent effective workspace limits explicitly so the UI, operator tooling, and enforcement path
share one source of truth. Recommended initial defaults are:

- 20 authorized runs per UTC day per workspace;
- 200 maximum provider calls reserved per UTC day per workspace;
- 200 maximum calls in any single run;
- the existing four validated model identifiers only.

All spend-producing paths must fail before planning or dispatching work when a limit would be
crossed, and the UI must show the limit, current committed amount, and reset boundary.

### Retention, closure, and deletion

Recommended alpha policy:

- while a workspace is active, retain versioned configuration, raw prompts/contexts/outputs, and
  evidence until the customer requests deletion; do not use it for model training;
- workspace closure immediately blocks access, new invitations, provider validation, and execution,
  pauses schedules, cancels unstarted work, and revokes credentials;
- a closed workspace is retained for 30 days for accidental-closure recovery unless the customer
  requests earlier deletion;
- an explicit deletion request is executed by an operator within 7 days;
- purge all tenant rows in a tested dependency order, retaining only a content-free deletion receipt
  outside the workspace foreign-key graph;
- disaster-recovery backups expire within 30 days, are not used for ordinary access, and any restore
  must reapply completed deletion receipts.

The purge must remove review/correction links, alert and baseline membership, capture evidence,
contracts, monitor versions/cases, credentials, setup/events, memberships/invitations, and finally
the workspace. A generic cascade is intentionally insufficient because sealed evidence has
restrictive foreign keys and immutability triggers.

### Encryption-key rotation

Use Cloak's tagged multi-key configuration. Add the new key first with a new tag, retain the old key
as a retired decrypt-only cipher, re-encrypt provider credentials, verify migration completion, and
remove the retired key only after the oldest backup that may contain old ciphertext has expired.
Production secrets stay outside the repository.

### Deployment readiness without deployment

Document, but do not create, Fly.io resources. Prefer managed PostgreSQL when deployment is
authorized. A restore drill must create an isolated database, restore a snapshot, verify migrations,
verify encrypted credential readability with the retained keyring, run smoke checks, and only then
change application connectivity.

## Security and Privacy Boundaries

- Log and exception metadata use an explicit safe-key allowlist.
- Phoenix parameter filtering remains defense in depth, not the primary boundary.
- Product events, audit events, Oban arguments, rate-limit buckets, and notification deliveries are
  each tested to exclude customer content and secrets.
- All new workspace views and mutations belong inside `/app/:workspace_slug` with
  `[:browser, :authenticated, :workspace_scope]` because their preferences, activation status, and
  evidence links are private tenant data.
- Operator-only purge and founder-assistance actions use explicit Mix tasks; they are not public or
  ordinary member routes.

## Approved Decision Gates

The owner approved the following choices on 16 September 2026:

1. Transactional provider: recommend Resend for the pilot because Swoosh 1.28 has a built-in
   adapter and Resend accepts idempotency keys; keep the Local adapter until deployment credentials
   and a verified sending domain exist.
2. Retention/deletion: recommend active-lifetime retention, 30 days after closure, deletion within
   7 days on explicit request, and backup expiry within 30 days.
3. Credential rotation: recommend a versioned Cloak keyring with new-default/retired keys and no old
   key removal until ciphertext migration and backup expiry are both verified.
4. Pilot limits/models: recommend 20 runs/day, 200 calls/day, 200 calls/run, and the existing
   validated OpenAI and Anthropic model allowlists.

## Risks

- A database limiter adds writes to sensitive endpoints; stale bucket cleanup must be bounded.
- Email delivery is an external side effect and cannot be perfectly atomic with PostgreSQL.
- Full tenant deletion is deliberately complex because reproducibility constraints prevent silent
  evidence loss; the operation must remain operator-controlled and extensively tested.
- Active-lifetime raw evidence retention is simple and reproducible but may be too long for some
  design partners; partner objections are a product signal and should cause a policy review.
- A 200-call daily cap bounds provider attempts, not currency; different providers and models have
  different token prices.

## References

- [Swoosh Local adapter](https://hexdocs.pm/swoosh/Swoosh.Adapters.Local.html)
- [Swoosh adapters](https://hexdocs.pm/swoosh/)
- [Oban unique jobs](https://hexdocs.pm/oban/unique_jobs.html)
- [Cloak.Ecto key rotation](https://hexdocs.pm/cloak_ecto/rotate_keys.html)
- [PostgreSQL atomic `ON CONFLICT`](https://www.postgresql.org/docs/current/sql-insert.html)
- [OWASP authentication guidance](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [OWASP logging guidance](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
- [Fly.io backup and restore](https://fly.io/docs/postgres/managing/backup-and-restore/)
