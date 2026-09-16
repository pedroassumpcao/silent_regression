# Pilot Readiness Implementation Plan

## Overview

Complete Task 14 in six focused phases. Work that changes customer-data retention, production mail,
encryption-key operations, or pilot spending remains gated by the decisions recorded in
`RESEARCH.md`.

## Phase 1: Activation and learning evidence

- [ ] Add the derived six-stage onboarding checklist.
- [ ] Extend the product-event schema and strict property allowlist.
- [ ] Record baseline approval, schedule activation, alert review, and corrective action.
- [ ] Add an operator-only founder-assistance event command.
- [ ] Add activation-funnel queries without exposing customer content.

## Phase 2: Notification outbox and preferences

- [ ] Add workspace/user actionable-alert email preferences.
- [ ] Add durable, deduplicated notification deliveries.
- [ ] Add the ID-only Oban email worker and content-free alert email.
- [ ] Add authenticated preference controls and delivery-status evidence.
- [ ] Retain the Local adapter until the approved provider is configured for deployment.

## Phase 3: Pilot limits and rate limiting

- [ ] Add explicit workspace run/call policies and usage presentation.
- [ ] Enforce run and call caps before planning or dispatch.
- [ ] Add hashed PostgreSQL fixed-window rate-limit buckets.
- [ ] Protect login, invitation acceptance, credential validation, and run authorization.
- [ ] Return clear retry and capacity errors without leaking account existence.

## Phase 4: Closure, retention, and deletion

- [ ] Add owner-governed closure with immediate execution shutdown and credential revocation.
- [ ] Add deletion requests and content-free deletion receipts.
- [ ] Implement and test the complete restrictive-FK-aware purge order.
- [ ] Add operator commands for closure recovery and due deletion execution.
- [ ] Document active, closed, deleted, and backup retention behavior.

## Phase 5: Security and operator readiness

- [ ] Add versioned production Cloak keyring support and rotation verification tooling.
- [ ] Test logs, exceptions, telemetry, Oban arguments, product events, and audit metadata against a
  sensitive-data denylist and safe-key allowlist.
- [ ] Write the operator runbook, incident procedures, backup/restore drill, key-rotation guide,
  alpha data notice, known limitations, and deployment-readiness checklist.
- [ ] Verify public registration and billing remain absent.

## Phase 6: End-to-end pilot gate

- [ ] Run the complete invited-user fake-provider journey without direct database intervention.
- [ ] Verify notification deduplication, preferences, caps, rate limits, closure, deletion, and
  cross-tenant isolation.
- [ ] Run TypeScript, frontend, asset, and full Elixir verification.
- [ ] Preview separate bounded OpenAI and Anthropic smoke contracts.
- [ ] Request explicit authorization immediately before each live provider smoke.
- [ ] Reconcile Task 14 and the private-alpha readiness checklist.

## Route Placement

Workspace checklist, notification preference, closure, and deletion-request routes belong inside
the existing `/app/:workspace_slug` scope with
`[:browser, :authenticated, :workspace_scope]`. The scope is required because these operations
expose private workspace state and must resolve an authenticated membership before authorization.

Login and invitation-acceptance rate limiting remains in the public browser pipeline because it
must run before authentication. Credential validation, baseline authorization, schedule activation,
and Run now remain in the authenticated workspace scope and combine rate limiting with existing
owner checks.

