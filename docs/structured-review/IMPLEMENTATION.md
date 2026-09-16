# Structured Review and Correction Implementation Plan

## Overview

Implement Task 13 as five ordered phases so immutable judgment and compatibility rules exist before
the UI can resolve alerts or activate corrected contracts.

## Phase 1: Review evidence foundation

- [x] Add append-only review-decision schema, constraints, supersession chain, and audit events.
- [x] Derive exact evidence identities for alert and observation subjects on the server.
- [x] Add current/history queries, review counts, and changed-judgment counts.
- [x] Verify tenant isolation, attribution, immutability, and stale supersession behavior.

## Phase 2: Governed alert and correction lifecycle

- [x] Require a current review decision before owner-only alert resolution.
- [x] Pin the exact resolution decision on the alert.
- [x] Add immutable review-to-contract-revision origins.
- [x] Preserve member authoring while retaining owner-only resolution and approval.

## Phase 3: Transactional contract rescore and compatibility

- [x] Extract reusable immutable evaluation persistence from capture execution.
- [x] Rescore all stored successful monitor observations under the successor contract.
- [x] Persist a rescore summary and abort activation on evaluator errors.
- [x] Reuse baselines across behavior-identical contract versions.
- [x] Require a new baseline when monitor behavior, contract semantics, evaluator, provider, model,
  or credential changes.

## Phase 4: Inertia review experience

- [x] Present review evidence and non-accuracy summary counts on run detail.
- [x] Add alert review and supersession dialogs.
- [x] Add observation-level missed-regression entry points.
- [x] Add direct contract-revision flow and approval rescore evidence.
- [x] Add safe empty, stale, permission, and validation states.

## Phase 5: Verification and handoff

- [ ] Add context, schema, controller, presenter, compatibility, and rescore tests.
- [ ] Add component tests for false alert, missed regression, supersession, and owner controls.
- [ ] Browser-test false alert, missed regression, and contract revision using the fake provider.
- [ ] Run type checking, frontend tests, asset build, and `mix precommit`.
- [ ] Reconcile Task 13 and the private-alpha plan.

## Route Placement

Review submission and review-origin contract revision routes will be placed inside the existing
`/app/:workspace_slug` scope with `[:browser, :authenticated, :workspace_scope]`. They require both
authentication and resolved membership because review rationale and the referenced run evidence are
private workspace data.
