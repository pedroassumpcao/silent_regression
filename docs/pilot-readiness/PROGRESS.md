# Pilot Readiness Progress

## Status: Phases 1–2 complete; Phase 3 next

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

**Status:** Not started

### Phase 4: Closure, retention, and deletion

**Status:** Not started

### Phase 5: Security and operator readiness

**Status:** Not started

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

## Blockers

- None.
