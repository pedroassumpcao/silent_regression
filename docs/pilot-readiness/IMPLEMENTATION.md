# Pilot Readiness Implementation Plan

## Overview

Complete Task 14 in six focused phases. Work that changes customer-data retention, production mail,
encryption-key operations, or pilot spending remains gated by the decisions recorded in
`RESEARCH.md`.

## Phase 1: Activation and learning evidence

- [x] Add the derived six-stage onboarding checklist.
- [x] Extend the product-event schema and strict property allowlist.
- [x] Record baseline approval, schedule activation, alert review, and corrective action.
- [x] Add an operator-only founder-assistance event command.
- [x] Add activation-funnel queries without exposing customer content.

## Phase 2: Notification outbox and preferences

- [x] Add workspace/user actionable-alert email preferences.
- [x] Add durable, deduplicated notification deliveries.
- [x] Add the ID-only Oban email worker and content-free alert email.
- [x] Add authenticated preference controls and delivery-status evidence.
- [x] Retain the Local adapter until the approved provider is configured for deployment.

## Phase 3: Pilot limits and rate limiting

- [x] Add explicit workspace run/call policies and usage presentation.
- [x] Enforce run and call caps before planning or dispatch.
- [x] Add hashed PostgreSQL fixed-window rate-limit buckets.
- [x] Protect login, invitation acceptance, credential validation, and run authorization.
- [x] Return clear retry and capacity errors without leaking account existence.

## Phase 4: Closure, retention, and deletion

- [x] Add owner-governed closure with immediate execution shutdown and credential revocation.
- [x] Add deletion requests and content-free deletion receipts.
- [x] Implement and test the complete restrictive-FK-aware purge order.
- [x] Add operator commands for closure recovery and due deletion execution.
- [x] Document active, closed, deleted, and backup retention behavior.

## Phase 5: Security and operator readiness

- [x] Add versioned production Cloak keyring support and rotation verification tooling.
- [x] Test logs, exceptions, telemetry, Oban arguments, product events, and audit metadata against a
  sensitive-data denylist and safe-key allowlist.
- [x] Write the operator runbook, incident procedures, backup/restore drill, key-rotation guide,
  alpha data notice, known limitations, and deployment-readiness checklist.
- [x] Verify public registration and billing remain absent.

## Phase 6: End-to-end pilot gate

- [x] Run the complete invited-user fake-provider journey without direct database intervention.
- [x] Verify notification deduplication, preferences, caps, rate limits, closure, deletion, and
  cross-tenant isolation.
- [x] Run TypeScript, frontend, asset, and full Elixir verification.
- [x] Preview separate bounded OpenAI and Anthropic smoke contracts.
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
