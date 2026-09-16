# Structured Review and Correction Research

## Overview

Task 13 turns design-partner judgment into durable evidence. A review is not an edit to an alert,
observation, evaluation, rule result, contract, or baseline. It is a new attributed decision tied to
those exact records. A later judgment supersedes the earlier decision through a linear append-only
chain, preserving what was known and decided at every point in time.

## Product Boundary

The private-alpha product needs to capture both detector mistakes:

- a false positive, when a contract-derived alert represents acceptable variation; and
- a false negative, when a passing observation should have failed.

The classification vocabulary therefore remains richer than thumbs up/down. Reviews distinguish a
confirmed regression, acceptable variation, contract or test-data problems, operational anomalies,
and uncertainty. Counts are shown as review evidence, not as model accuracy; the alpha does not yet
have enough representative labels to justify an accuracy claim.

## Selected Domain Model

### Append-only review decisions

Each review decision stores:

- workspace, monitor, run, contract version, and pinned baseline identities;
- exactly one review subject: an alert or an observation;
- the exact evaluation and optional rule result when applicable;
- reviewer identity, classification, optional rationale, and one resulting action;
- a stable review key and an optional predecessor decision.

The first decision is unique for a review key. Every successor points to exactly one predecessor,
and a predecessor can have at most one successor. The current decision is the chain leaf, found by
the absence of a successor. This avoids a mutable `current` flag while database indexes prevent
forked review history under concurrency. PostgreSQL rejects updates and deletes to review rows.

### Classifications

- `correct_pass`
- `confirmed_regression`
- `acceptable_variation`
- `contract_needs_revision`
- `test_case_or_baseline_problem`
- `passed_but_should_have_failed`
- `unsure`
- `operational_anomaly`

### Resulting actions

- `none`
- `prompt_change`
- `case_change`
- `contract_revision`
- `provider_change`
- `operational_follow_up`

One primary action is sufficient for the closed alpha and produces analyzable data without a second
workflow system. A later review may supersede the action as well as the classification.

### Alert resolution

Acknowledgement remains a lightweight member action. Owner-only resolution now requires a current
review decision for that alert and stores the exact decision that justified the resolution. A later
superseding review does not rewrite or reopen the resolved alert; both the original resolution basis
and the corrected judgment remain reproducible.

### Contract revision origin

A current review whose action is `contract_revision` can create or join the monitor's successor
draft. An immutable origin row links the review decision to that draft, including when another
review already caused the draft to exist. Members may author and attach review evidence; only an
owner may approve the successor, preserving the existing permission model.

## Rescoring Before Contract Activation

Approval of a contract successor runs the deterministic evaluator against every stored successful
observation for that monitor inside the same database transaction. Evaluations are new immutable
records tied to the successor contract; original evaluations remain unchanged. A compact immutable
summary records pass, fail, evaluator-error, and observation counts.

Any evaluator error aborts approval. The previous approved contract remains active because rescoring,
retirement, successor approval, and summary persistence share one transaction. Rescoring makes zero
provider calls.

## Baseline Compatibility

A baseline is reusable only when monitored behavior and interpretation are unchanged:

- monitor fingerprint and case-set fingerprint match;
- provider credential, provider, and requested model match;
- deterministic contract fingerprint and evaluator engine version match.

Contract row identity is provenance, not semantic compatibility. A successor that changes only
fixtures, assistance metadata, or version identity can reuse the approved baseline. A rule change,
evaluator change, prompt/case/model/provider change, or credential change requires a new baseline.
Run detail still shows both contract version IDs so users can see that identical semantics were
carried across a version boundary.

## UI and Authorization

- Alert cards expose the current judgment, decision history, and a structured review dialog.
- Every observation has a missed-regression entry point, including passing observations with no
  alert.
- Review summaries show current decision counts and changed-judgment counts, never “accuracy.”
- A contract-revision action offers a direct transition to the linked successor draft.
- Members may submit/supersede reviews and acknowledge alerts.
- Only owners may approve contracts or resolve reviewed alerts.
- All routes remain in the authenticated workspace-scoped controller pipeline because prompts,
  outputs, judgments, and corrections are private tenant data.

## Safety and Concurrency

- Server-side target loading derives every evidence identity; clients cannot nominate a foreign
  contract, baseline, evaluation, or run.
- An expected-current-decision ID provides optimistic concurrency feedback in addition to database
  uniqueness.
- Review rationales are bounded plain text and rendered through React's normal escaping.
- Rescoring is local, deterministic, and transactional.
- Immutable database triggers protect review decisions, revision origins, and rescore summaries.

## Deferred Productization Work

- Multi-action remediation workflows and task ownership.
- Reopening policy for alerts after materially changed judgments.
- Inter-reviewer adjudication and calibrated agreement metrics.
- Sampling/retention limits for very large historical observation sets.
- Accuracy, precision, or recall claims after a representative labeled corpus exists.

## References

- PostgreSQL constraints: https://www.postgresql.org/docs/16/ddl-constraints.html
- PostgreSQL partial unique indexes: https://www.postgresql.org/docs/16/sql-createindex.html
- Ecto transactions and `Ecto.Multi`: https://hexdocs.pm/ecto/Ecto.Multi.html
- Ecto database constraints: https://hexdocs.pm/ecto/Ecto.Changeset.html
