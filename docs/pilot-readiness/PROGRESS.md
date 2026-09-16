# Pilot Readiness Progress

## Status: Phases 1–5 complete; Phase 6 next

## Quick Reference

- Research: `docs/pilot-readiness/RESEARCH.md`
- Implementation: `docs/pilot-readiness/IMPLEMENTATION.md`
- Parent plan: `plans/private_alpha_implementation_plan.md`, Task 14

## Phase Progress

### Phase 1: Activation and learning evidence

**Status:** Complete

### Phase 2: Notification outbox and preferences

**Status:** Complete

### Phase 3: Pilot limits and rate limiting

**Status:** Complete

### Phase 4: Closure, retention, and deletion

**Status:** Complete

### Phase 5: Security and operator readiness

**Status:** Complete

### Phase 6: End-to-end pilot gate

**Status:** Not started

## Decision Gates

- [x] Transactional email provider and local-until-deployment boundary approved: keep Local now and
  use Resend for deployment.
- [x] Raw content retention, closure retention, deletion SLA, and backup expiry approved: retain raw
  evidence while active, retain closed workspaces for 30 days, execute explicit deletion within 7
  days, and expire disaster-recovery backups within 30 days.
- [x] Versioned Cloak keyring and rotation procedure approved: a new default key plus retired
  decrypt-only keys, with old-key removal only after ciphertext migration and backup expiry.
- [x] Workspace run/call caps and supported model allowlists approved: 20 authorized runs/day, 200
  reserved calls/day, 200 calls/run, and the existing OpenAI and Anthropic allowlists.

## Session Log

### 2026-09-16

- Audited Task 14 against authentication, workspace, provider credential, setup, product event,
  capture, baseline, scheduling, alert, review, Swoosh, Oban, and runtime configuration code.
- Confirmed the existing product-event stream is first-party, append-only, and content-free but ends
  at setup completion.
- Confirmed local/test email adapters, model allowlists, credential revocation, per-run maximum calls,
  and a 200-call daily workspace envelope already exist.
- Selected derived activation state, strict first-party events, a database notification outbox,
  PostgreSQL fixed-window rate limits, explicit workspace pilot policy, and ordered tenant purge as
  the recommended architecture.
- Paused customer-data-affecting implementation at the four explicit Task 14 decision gates.
- Received owner approval for all four decision gates.
- Added a six-stage checklist derived from credentials, setup, cases, contract, baseline, and active
  daily/weekly scheduling rather than storing mutable checklist flags.
- Extended the content-free product event stream through baseline approval, schedule activation,
  review, corrective action, and allowlisted founder-assistance evidence.
- Added activation-funnel queries and an owner-attributed operator command for recording bounded
  assistance metadata without accepting notes or customer content.
- Verified the focused Elixir tests and the complete TypeScript/frontend suite.
- Added a workspace/member preference that defaults to actionable-alert email enabled and is
  rechecked immediately before delivery.
- Added one database delivery per alert, recipient, and channel, with immutable identity, bounded
  status metadata, and an ID-only Oban job on the dedicated notifications queue.
- Added content-minimized alert email and an authenticated preference screen inside the existing
  workspace scope. The Local adapter remains active until deployment configuration is supplied.
- Verified outbox deduplication, preference suppression, retry idempotency, delivery state, safe
  email content, workspace authorization, and the complete frontend suite.
- Persisted the approved 20-run/day, 200-call/day, and 200-call/run policy per workspace, while
  retaining the existing two-model OpenAI and two-model Anthropic allowlists.
- Centralized atomic pre-insert capacity enforcement in capture planning so baseline, manual, and
  scheduled runs cannot bypass limits through a lower-level entry point.
- Added current UTC usage, remaining run/call capacity, per-run limit, and reset time to monitor
  operations.
- Added atomic PostgreSQL fixed-window limits for login, invitation acceptance, credential/model
  validation, schedule activation/resumption, baseline authorization, and Run now.
- Stored only HMAC digests for rate-limit subjects and returned generic HTTP 429 responses with a
  `Retry-After` boundary. Focused tests verified raw emails and IPs never enter limiter rows.
- Added owner-only close and deletion-request controls with exact workspace-slug confirmation inside
  the authenticated workspace route scope.
- Closure now cancels active capture work and notification jobs, pauses active monitors, revokes
  provider credentials and pending invitations, and immediately removes tenant access.
- Added a 30-day recoverable closure path, an irreversible deletion-request path due immediately,
  and content-free HMAC-fingerprinted deletion receipts without workspace foreign keys.
- Added narrowly transaction-scoped purge support to the database's immutable-history triggers and
  verified the restrictive evidence graph can be deleted without weakening ordinary immutability.
- Added guarded operator commands for dry-run purge preview, due purge execution, and owner-verified
  recovery. Shared accounts survive when they retain another workspace membership.
- Documented active, closed, deleted, and disaster-recovery backup behavior in
  `docs/pilot-readiness/DATA_RETENTION.md`.
- Added production Cloak V1/V2 keyring configuration: V2 becomes the encrypting default when
  present while V1 remains available to decrypt historical ciphertext. Production now fails closed
  without versioned encryption, rate-limit HMAC, and deletion-receipt HMAC keys.
- Added dry-run-first credential key inventory and exact-tag-confirmed re-encryption tooling. It
  reports only tags and counts, verifies decryptability, and refuses to declare success while any
  row remains outside the active tag.
- Configured production email for Swoosh's Resend adapter over the existing Req client while leaving
  Local/Test adapters unchanged outside production.
- Added an explicit audit action/metadata allowlist and a sensitive-data boundary suite covering
  audit records, product events, Phoenix filtering, and key inventory. The complete 593-test backend
  suite passed after the boundary was enabled.
- Updated the public Security, Privacy, and private-alpha Terms pages to describe the implemented
  invite-only workspace, retention, credential, and deletion boundaries.
- Added operator, incident-response, backup/restore, key-rotation, alpha data, and future deployment
  documents. A route-level test confirms public registration, billing, and checkout remain absent.

## Blockers

- None.
