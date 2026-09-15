# Baseline Capture, Inspection, and Approval Research

## Overview

Task 10 turns the durable execution path from Task 9 into the first customer-authorized provider
spend and the immutable reference required by later scheduling and comparison work. The flow must
make the exact call envelope visible before authorization, persist who authorized it, show durable
progress and evidence, and seal an approved baseline without treating operational anomalies as
content quality.

Task 10 does not add recurring schedules, general run history, alerts, or structured result review.
Those remain Tasks 11–13.

## Tasks 1–9 readiness audit

The completed foundation was audited before Task 10 began. The audit did not rely only on checked
boxes in the implementation plan.

| Foundation | Evidence reviewed | Result for Task 10 |
| --- | --- | --- |
| Phoenix/Inertia/React/shadcn | Authenticated route boundary, shared props, frontend types/tests, and production asset build | Ready; type checking, all 15 component tests, and the production build pass |
| Public and invite-only access | Public/private route split, invitation and session tests, workspace scope, owner/member authorization, and indistinguishable cross-tenant responses | Ready; baseline routes will remain under `:authenticated` and `:workspace_scope` |
| Provider credentials | Encrypted storage, safe projections, owner lifecycle controls, fake providers, and prior manually authorized OpenAI/Anthropic validation | Ready; the worker resolves a valid same-workspace credential at execution time |
| Immutable monitor configuration | Candidate/active version lifecycle, fingerprints, case bounds, database immutability, and compatibility checks | Ready; Task 10 must activate the exact contract-approved candidate before authorizing its first capture |
| Persisted setup and contract approval | Completed setup snapshot, approved exact contract, fixture evidence, owner approval, and sealed fingerprints | Ready; the setup intentionally ends with a candidate rather than spending provider calls |
| Durable execution | Oban queues, identifier-only jobs, attempt leases, hard call caps, normalized provider evidence, and exact-contract local evaluation | Ready; all 14 focused capture tests and all 495 repository tests pass |
| Database state | Development and test migration status | Ready; all ten migrations are applied in both environments |

There are no forgotten acceptance items in Tasks 1–9. The following remain deliberate later gates:

- legal review of the public privacy and terms placeholders before an external pilot;
- production encryption-key operations, rate limits, workspace quotas, retention/deletion, and the
  operator runbook in Task 14;
- Inertia v3 until the Phoenix adapter has a stable compatible release;
- ReqLLM until the direct provider boundary can be compared without weakening provenance or call
  accounting; and
- frontend bundle optimization. The current production build succeeds, though the main application
  bundle warning should be revisited before pilot readiness rather than expanding Task 10.

## Problem statement

A baseline provider call is billable and irreversible. A browser button must not be the only proof
that the customer understood the scope, and a completed background job must not automatically
become an approved reference. The product needs three distinct boundaries:

1. a read-only preflight generated from current server state;
2. an explicit, attributable authorization that creates and enqueues one exact capture plan; and
3. a separate approval that seals reviewed observations as the compatible reference.

## User stories

- As a workspace owner, I can see the provider, exact model, cases, sample count, retry policy, and
  worst-case requests before any provider call.
- As a workspace owner, I can explicitly authorize that exact plan and safely retry the browser
  submission without duplicating the run.
- As a workspace member, I can inspect capture progress and results without being able to authorize
  spend or approve the reference.
- As a reviewer, I can distinguish successful complete outputs, incomplete outputs, provider
  failures, unknown outcomes, model mismatches, deterministic failures, and evaluator errors.
- As a workspace owner, I can approve a healthy baseline normally or exceptionally accept only
  deterministic failures with a required rationale.
- As a later scheduler, I can determine whether an approved baseline is still compatible with the
  current monitor and approved contract without guessing from mutable state.

## Technical approach

### Selected persistence model

Add `BaselineSnapshot` and `BaselineMember` product records.

A snapshot begins in `pending` when an owner authorizes an exact preflight. It references the
immutable capture run and stores the preflight fingerprint, exact monitor/contract/provider/model
provenance, sample and call envelope, authorizer, and authorization timestamp. It may become:

- `approved` after evidence review;
- `superseded` when a replacement authorization or approval takes precedence; or
- `rejected` when the owner explicitly abandons it.

Approval adds an approval mode (`normal` or `exceptional`), approver, timestamp, and optional
rationale. Each `BaselineMember` seals one exact observation ID plus its case/sample identity and
fingerprints. Database constraints, partial uniqueness, and triggers protect pending plan identity,
terminal approval evidence, and membership rows.

The snapshot row doubles as the durable authorization record. `Captures.enqueue_run/2` will refuse
to enqueue a baseline-kind run unless its pending snapshot exists. That makes the authorization
requirement a domain invariant rather than a controller convention.

### Monitor activation boundary

Setup completion deliberately creates a complete candidate version without activating it. Contract
approval is tied to that candidate. At baseline authorization, the product will atomically promote
that exact version and move the monitor to `baseline_pending` before planning calls. Capture planning
will use the active version rather than rediscovering a version through setup history.

This closes the integration boundary without moving provider spend into setup or contract
authoring. A later behavior-affecting candidate or newly approved contract makes the existing
baseline incompatible until a replacement is approved.

### Preflight and idempotency

The server computes preflight data from current database state on every request. Client-submitted
counts are never trusted. The preview contains:

- case count and exact case identities;
- samples per case, planned calls, one known-failure retry, and maximum calls;
- the per-run alpha cap and remaining headroom;
- configured maximum output tokens per request and the worst-case output-token ceiling;
- provider, requested model, credential safe label/suffix/status;
- monitor, case-set, and approved-contract fingerprints; and
- blockers for configuration, credential, contract, case, cap, or lifecycle problems.

The deterministic-only private alpha defaults to one sample per case and permits one through five.
With at most 20 active cases and one retry, the existing 200-call hard cap remains enforceable.

Every rendered authorization form receives a UUID authorization key. The owner posts that key and
the selected sample count. The database uses the key for run identity and snapshot uniqueness, so a
double submission returns the same plan rather than creating duplicate spend.

The preview's canonical fields are hashed into a fingerprint stored on the pending snapshot. The
authorization action recomputes the preview under row locks and rejects stale forms rather than
silently authorizing changed bytes.

### Durable progress and polling

The baseline page derives progress from persisted run, observation, attempt, evaluation, and rule
rows. It does not depend on an in-memory browser process.

Use Inertia React's `usePoll` with a two-second interval while the run is non-terminal, requesting
only the baseline progress prop. Polling stops when the page unmounts or the run becomes terminal;
background-tab throttling remains enabled. This matches the installed Inertia v2 client and avoids
adding a WebSocket protocol before the alpha needs one.

### Health and approval policy

Operational readiness and deterministic judgment remain separate.

Both normal and exceptional approval require:

- the exact pending snapshot and compatible approved contract;
- a terminal provider-success run with every planned observation present;
- every observation complete rather than incomplete or unknown;
- requested and returned models equal;
- an evaluation for every observation; and
- no evaluator errors.

Normal approval additionally requires every deterministic evaluation to pass.

Exceptional approval may accept deterministic failures only. It requires an owner-entered rationale
and never overrides missing observations, provider failures, incomplete completions, unknown
outcomes, model mismatches, or evaluator errors. This keeps operational uncertainty out of the
baseline while allowing a reviewed contract exception to remain explicit and attributable.

Approval supersedes the previous approved compatible baseline and inserts all membership rows in
one database transaction. It does not activate a schedule; Task 11 owns the transition from
`baseline_pending` to `active`.

## UI approach

Use one responsive `Monitors/Baseline` Inertia page with four derived phases:

1. **Blocked preflight:** show precise blockers and links back to credential, setup, or contract.
2. **Ready to authorize:** show exact spend/call preview, sample selector, data-use explanation, and
   owner-only authorization action.
3. **Capturing:** show durable planned/attempted/terminal counts and categorized progress while
   polling.
4. **Review or approved:** show each case/sample output, completion/model/usage/latency provenance,
   deterministic rule results, operational anomalies, and the applicable approval action.

The page will not introduce Task 12's general run history, alert policies, or comparison scores.

## Integration points

- `SilentRegression.Monitors` promotes the exact candidate to `baseline_pending`.
- `SilentRegression.Captures` plans and executes the authorized run and exposes durable evidence.
- `SilentRegression.ContractAuthoring` supplies the exact approved contract identity.
- `SilentRegression.Audit` records authorization, approval, rejection, and supersession without raw
  prompts, contexts, outputs, or secrets.
- The authenticated workspace router hosts baseline show, authorize, approve, and reject actions.
- Dashboard and sealed-contract actions lead to the baseline page when appropriate.

## Risks and mitigations

- **Double clicks or replayed POSTs:** authorization-key and run identity uniqueness make the action
  idempotent.
- **Configuration changes between preview and POST:** recompute and compare the preview fingerprint
  under locks.
- **Approval of operationally incomplete evidence:** exceptional approval cannot bypass operational
  blockers.
- **Mutable membership:** explicit member rows and database triggers prevent silent rewriting.
- **Polling overload:** two-second partial reloads run only while non-terminal and retain Inertia's
  background throttling.
- **Misleading cost estimates:** present exact request and output-token ceilings, not currency or
  provider-account quota claims the product cannot know.
- **Cross-tenant access:** every browser and context entry point requires the verified workspace
  scope; unknown and foreign IDs remain indistinguishable.

## Implementation phases

1. Add snapshot/member persistence, monitor promotion, preflight, authorization, approval, and
   database invariants with context tests.
2. Add authenticated workspace routes, controller projections, responsive React flow, partial
   polling, and frontend/controller tests.
3. Run the complete fake-provider browser flow and full verification suite.
4. Present one exact live-call preview and wait for explicit user authorization before the required
   live smoke test.

The private-alpha implementation plan remains the authoritative progress tracker; this document
records Task 10's detailed design rather than creating a competing progress file.

## References

- [Inertia v2 polling](https://inertiajs.com/docs/v2/data-props/polling)
- [Inertia v2 partial reload protocol](https://inertiajs.com/docs/v2/core-concepts/the-protocol)
- [Ecto transactions and repositories](https://ecto.hexdocs.pm/Ecto.Repo.html)
- [Ecto.Multi](https://ecto.hexdocs.pm/Ecto.Multi.html)
- [Oban 2.24 API](https://oban.hexdocs.pm/Oban.html)
- [Task 9 capture execution design](../capture-execution/RESEARCH.md)
- [Versioned monitor design](../monitors/RESEARCH.md)
- [Private-alpha implementation plan](../../plans/private_alpha_implementation_plan.md)
