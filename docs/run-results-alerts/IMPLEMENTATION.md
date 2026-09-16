# Run Results and Alerts Implementation Plan

## Overview

Build the complete Task 12 vertical slice on the existing immutable capture evidence. The work is
split so provenance and policy are correct before alerts or pages depend on them.

## Prerequisites

- Tasks 9–11 are complete.
- Capture observations, provider attempts, evaluations, and rule results are durable.
- An approved baseline is required by monitor operations before manual or scheduled work.
- The authenticated Inertia product shell and existing shadcn primitives are available.

## Phase Summary

1. Freeze rule severity and baseline provenance.
2. Add the durable alert policy, generation, and lifecycle.
3. Add workspace-scoped result queries and safe presenters.
4. Build the alert inbox, monitor history, and run-detail experience.
5. Verify idempotency, authorization, safety, responsiveness, and the fake-provider journey.

---

## Phase 1: Severity and Provenance

### Objective

Make every future alert traceable to a stable severity and exact baseline snapshot.

### Tasks

- [x] Accept optional `critical` or `warning` severity on deterministic rules without changing old fingerprints.
- [x] Persist severity on immutable rule results.
- [x] Add an optional baseline snapshot reference to capture runs.
- [x] Pin new manual/scheduled plans to the current compatible baseline when available.
- [x] Include the baseline reference in immutable run-plan protection and idempotency matching.

### Success Criteria

Old contracts behave identically; new warning rules survive evaluation persistence; managed runs
retain exact baseline identity.

---

## Phase 2: Alert Domain and Policy

### Objective

Create explainable alerts once, even across retries and concurrent synchronization.

### Tasks

- [x] Add the alert schema, constraints, lifecycle actors/timestamps, and database uniqueness.
- [x] Implement provenance compatibility and baseline-relative metric comparison.
- [x] Implement decisive contract severity and grouped operational findings.
- [x] Synchronize terminal run outcomes idempotently from the observation worker.
- [x] Implement member acknowledgement and owner-only resolution with audit events.

### Success Criteria

Repeated synchronization produces no duplicates; every alert has a stable evidence path and category;
invalid lifecycle or cross-workspace access is rejected.

---

## Phase 3: Result Queries and Presenters

### Objective

Expose bounded, tenant-scoped product data without losing explainability.

### Tasks

- [x] Query workspace alerts, monitor run history, and one exact run detail.
- [x] Compute explicit run counts, usage, latency, attempts, and deterministic outcomes.
- [x] Present pinned baseline/current provenance and compatibility mismatches.
- [x] Allowlist provider diagnostic metadata and redact sensitive diagnostic keys.
- [x] Bound long UTF-8 text and structured evidence for browser payloads.

### Success Criteria

Controller props contain no credentials, authorization material, or unbounded diagnostic values, and
all counts retain denominators.

---

## Phase 4: Inertia Product Experience

### Objective

Let members inspect evidence and let authorized users move alerts through the simple lifecycle.

### Tasks

- [x] Enable the workspace Alerts navigation and inbox.
- [x] Build the monitor result overview and run-history page.
- [x] Build the run detail page with case/observation/evaluation/rule evidence.
- [x] Add acknowledgement and owner-only resolution actions.
- [x] Link operations and dashboard surfaces to formal results.
- [x] Add empty, in-progress, partial, stale, and no-alert states.
- [x] Constrain long plain-text content for mobile and desktop layouts.

### Success Criteria

A reviewer can navigate from alert to exact evidence and explain why it exists. Operational language
never implies content degradation.

---

## Phase 5: Verification and Handoff

### Objective

Prove the Task 12 acceptance criteria and record the implementation boundary for Task 13.

### Tasks

- [x] Add policy, lifecycle, provenance, presenter, controller, and cross-tenant tests.
- [x] Add frontend evidence, lifecycle, empty-state, and responsive-class tests.
- [ ] Run a browser journey from a fake completed run through alert inspection and resolution.
- [ ] Run frontend checks, asset build, and `mix precommit`.
- [ ] Complete the private-alpha plan and progress records.

### Success Criteria

All Task 12 checks pass, no real provider call is made, and Task 13 can build structured review on
stable alert/evidence identities.

## Post-Implementation

- [ ] Revisit policy thresholds after design-partner evidence exists.
- [ ] Add append-only review judgments in Task 13.
- [ ] Add deduplicated email notification processing in Task 14.

## Notes

- No new frontend primitive is planned; the installed alert, badge, button, card, dialog, skeleton,
  and table components cover the slice.
- No new runtime dependency is planned.
- Result routes remain in the authenticated workspace-scoped controller pipeline.
