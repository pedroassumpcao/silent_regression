# Silent Regression Private Alpha — Implementation and Progress Plan

> **Status:** Task 7 in progress
>
> **Progress:** 6 of 14 tasks complete
>
> **Last revised:** 2026-09-15
>
> **Release target:** Invite-only design-partner alpha
>
> **Purpose:** Authoritative implementation sequence and progress tracker for turning the completed feasibility spike into the smallest useful hosted product

This plan narrows the broader [productization plan](productization_plan.md) into a private alpha that can be used with design partners. It does not reopen the completed spike or authorize the deferred semantic-layer work in [semantic_layer_plan.md](semantic_layer_plan.md).

The private alpha is a learning instrument. It must let a real customer complete the full monitoring loop securely, but it must not acquire conventional SaaS machinery merely to look complete.

## 1. How to use this document

Before beginning a task, Codex must read this document and the current progress notes for that task. Work on one numbered task at a time unless the user explicitly approves parallel work.

For every task:

1. Change its status from `Not started` to `In progress`.
2. Confirm any decision gate listed for the task.
3. Implement only the task's defined scope.
4. Run its task-specific verification.
5. Run `mix precommit` before marking the task complete.
6. Update the task checklist, decision log, progress table, and session log.
7. Create focused commits. Record the commit hashes in this document.

Allowed status values are `Not started`, `In progress`, `Blocked`, `Complete`, and `Deferred`.

An unchecked task is not complete merely because code exists. Its acceptance criteria and verification must pass.

## 2. Product objective

Build an invite-only application through which a design partner can:

1. Accept an invitation and enter an isolated workspace.
2. Store and validate an OpenAI or Anthropic credential securely.
3. Define one monitored LLM workflow using a prompt, model configuration, frozen context, and representative inputs.
4. Configure and approve deterministic output expectations.
5. Validate the expectations against known valid and invalid examples.
6. Preview and explicitly authorize an initial baseline capture.
7. Inspect and approve the captured baseline.
8. Run the monitor manually or schedule it daily or weekly.
9. Inspect exact evidence for every passing and failing rule.
10. Classify results, identify false alerts and missed regressions, and revise the contract through a new version.

Customers do not install an SDK or production library. Silent Regression performs managed replay using customer-provided inputs and credentials.

### 2.1 Initial product statement

> Silent Regression continuously replays critical LLM workflows and alerts when user-approved output contracts fail.

### 2.2 Initial customer fit

The alpha is designed for workflows with explicit, machine-checkable requirements, especially:

- structured extraction and JSON outputs;
- classification and routing;
- grounded RAG or support answers with required citations;
- required abstention when evidence is missing;
- allowed values, numeric ranges, and prohibited output conditions; and
- policy or compliance language that can be stated deterministically.

It is not positioned as general quality monitoring for unconstrained chat, creative writing, open research, dynamic retrieval quality, autonomous agents, or highly personalized generation.

## 3. Decisions already made

| Decision | Alpha choice |
| --- | --- |
| Access | Private and invite-only |
| Accounts | Authenticated users in isolated workspaces |
| Billing | No Stripe, checkout, plan selection, or subscription state |
| Entitlement | Internally assigned `Design Partner Access` |
| Backend | Elixir, Phoenix 1.8, Ecto, PostgreSQL |
| Product frontend | React, TypeScript, Inertia.js, Tailwind CSS 4, shadcn/ui |
| Providers | OpenAI and Anthropic |
| Provider HTTP boundary | Existing `Req`-based adapters behind a normalized provider behaviour |
| Evaluation | Deterministic contracts only |
| Comparison | Same workflow version, provider, requested model, effective configuration, and approved baseline |
| Input source | Customer-supplied prompt, frozen context, representative cases, and provider credentials |
| Execution | Managed replay; no customer SDK |
| Cadence | Manual, daily, or weekly |
| Feedback | Structured result review, including false alerts and missed regressions |
| Deployment | Fly.io eventually, but no deployment work until the local pilot-readiness gate passes |

## 4. Recommended architecture decisions

These are defaults for the plan. If the user changes one, update this document before implementing the affected task.

### 4.1 Hybrid web boundary

Mirror the useful boundary in the local `high_school` reference repository:

- Public marketing, privacy, terms, and design-partner application pages remain server-rendered HEEx for a small, fast, indexable surface.
- The authenticated product is implemented with Phoenix controllers rendering React pages through Inertia.
- Phoenix owns routing, sessions, authorization, validation, persistence, and business rules.
- React owns product interaction and presentation; it does not duplicate domain rules.
- No independent REST API is introduced merely to connect the browser to Phoenix. Add JSON endpoints only for interactions that genuinely need them.

### 4.2 Authentication and tenancy

- Start from Phoenix 1.8 generated authentication and retain its token/session security model.
- Adapt user-facing authentication screens to the agreed web boundary rather than keeping a second product UI stack.
- Disable public registration.
- Use email invitation tokens for design partners.
- Model a `Workspace` as the tenant and billing boundary even though billing is absent.
- Support `owner` and `member` roles only.
- Put the current user, workspace, and membership in a Phoenix `Scope` passed to every workspace-owned context operation.
- Never provide an unscoped public query for tenant-owned records.

### 4.3 Provider credentials

- Store provider keys only because scheduled replay requires server-side access.
- Encrypt credential values at the application layer with AES-GCM using a runtime key that is never stored in the database.
- Use `Cloak.Ecto` with AES-256-GCM and a versioned application keyring whose production key material is supplied at runtime.
- Never return a stored secret to React after creation.
- Never place a secret in logs, exception metadata, analytics events, URLs, Oban arguments, or run artifacts.
- Show only provider, user-defined label, status, last validation time, and a non-secret suffix or fingerprint.

### 4.4 Durable work

- Use PostgreSQL-backed Oban jobs for manual, baseline, and scheduled captures.
- Store per-monitor cadence and `next_run_at` in application tables.
- Use a small recurring dispatcher to enqueue due monitors rather than generating arbitrary user cron entries.
- Enforce uniqueness and idempotency for a monitor and scheduled time window.
- Treat provider retries as real calls that consume the configured call budget.

### 4.5 Provider library boundary

The product domain must depend on a provider behaviour, not on `Req`, ReqLLM, or a provider-specific response shape. Reuse the spike's proven request provenance and call-accounting logic where it remains generic.

Do not adopt ReqLLM merely because `high_school` uses it. Reconsider it only after the private alpha has a stable normalized provider contract and compare it against direct `Req` adapters for provenance fidelity, retry visibility, model coverage, testability, and maintenance cost.

### 4.6 Spike isolation

- Keep `SilentRegression.Spike` intact as experimental evidence and regression reference.
- Product code must not call Mix tasks or read spike JSON artifacts at runtime.
- Move or rewrite reusable deterministic logic under product namespaces with product schemas, versioning, explanations, and independent tests.
- Do not ship the lexical or handcrafted semantic representations that failed their held-out gates.

## 5. What to borrow from `high_school`

The local repository at `/Users/pedro/projects/high_school` is a reference, not a dependency and not a source to copy wholesale.

| Borrow the pattern | Adapt for Silent Regression |
| --- | --- |
| Inertia plug, controller rendering, title helper, React page resolution | Use current `inertia` versions and TypeScript-first pages |
| `assets/components.json`, `@` aliases, `cn` helper, shadcn primitives | Initialize with the current shadcn CLI; preview registry changes before writing |
| Workspace-like scope containing user, organization, and membership | Rename the tenant to `Workspace`; require it in all tenant-owned queries |
| Slug-scoped authenticated routes | Use `/app/:workspace_slug/...` and verify membership before assigning the scope |
| React application layout and responsive navigation | Build a monitoring-specific shell rather than copying One Sideline navigation or branding |
| Onboarding provider/checklist concept | Derive progress from persisted monitor state rather than manually toggled checklist flags |
| Oban supervision and manual test mode | Add monitor-specific queues, uniqueness, call budgets, and idempotency |
| Public HEEx pages separate from the Inertia product | Keep only the few pages needed for credibility and design-partner recruitment |

Do not carry over Stripe billing, subscription gates, public registration, broad SEO routes, app-specific analytics, domain modules, or external/inline asset patterns that conflict with this repository's `AGENTS.md`.

## 6. Scope

### 6.1 Included in the private alpha

- Invite-only authentication and workspace membership.
- One workspace may have multiple invited users.
- OpenAI and Anthropic credential storage, validation, rotation, and revocation.
- Monitor creation with versioned prompt, context, cases, provider/model, and generation configuration.
- Manual case entry and versioned JSON import.
- Deterministic contract templates and explicit rule configuration.
- Positive and negative fixture validation before contract approval.
- Explicit baseline authorization and approval.
- Manual, daily, and weekly durable runs.
- Exact planned-versus-actual provider call accounting.
- Run history, observations, deterministic evidence, and operational provenance.
- In-app alerts plus one email notification path for actionable failures.
- Structured review and contract revision.
- A derived onboarding checklist and first-party learning events.
- A minimal public site and design-partner application form.
- Customer data deletion and credential revocation suitable for a controlled pilot.

### 6.2 Explicitly deferred

- Stripe, paid plans, trials, invoices, metering, and customer billing portals.
- Public self-service registration.
- Fly.io deployment and production infrastructure.
- Semantic judges, embeddings, lexical drift alerts, or generalized quality scores.
- Cross-provider/model comparisons and migration simulations.
- Production SDKs, tracing, webhooks, or live traffic ingestion.
- Slack, Teams, PagerDuty, or configurable notification integrations.
- Arbitrary cron expressions and advanced scheduling.
- SSO, SCIM, complex RBAC, enterprise audit exports, and regional hosting.
- User-authored executable code or arbitrary regular expressions.
- A broad blog, programmatic SEO, or AI-mention content program.

## 7. Target domain model

Exact migrations are finalized in their owning task. These boundaries are part of the architecture and should not be collapsed for short-term convenience.

| Entity | Responsibility and important data |
| --- | --- |
| `User` / `UserToken` | Phoenix-generated identity, sessions, invitation acceptance, and login tokens |
| `Workspace` | Tenant boundary, name, slug, status, timezone, and alpha entitlement |
| `Membership` | User-to-workspace relationship with `owner` or `member` role |
| `Invitation` | Hashed, expiring invitation token, email, workspace, role, inviter, acceptance state |
| `DesignPartnerApplication` | Public request-access submission and internal review status |
| `ProviderCredential` | Workspace, provider, label, encrypted secret, fingerprint/suffix, state, validation metadata |
| `Monitor` | Stable identity, name, lifecycle state, active version references, cadence, and `next_run_at` |
| `MonitorVersion` | Immutable provider/model, prompts, response format, generation config, and compatibility fingerprint |
| `CaseVersion` | Immutable name, frozen variables/context, position, status, and fingerprint |
| `ContractVersion` | Immutable schema version, configured rules, fixture references, approval state, fingerprint, approver |
| `ContractFixture` | Known-valid or known-invalid customer example and its expected rule outcomes |
| `BaselineSnapshot` | Approved monitor, workflow, case, contract, provider provenance, and member observations |
| `CaptureRun` | Baseline/manual/scheduled purpose, lifecycle, plan, call budget, counts, timestamps, and terminal reason |
| `Observation` | Immutable normalized response, completion state, requested/returned model, usage, latency, safe request ID, and errors |
| `Evaluation` | Observation, contract version, evaluator engine version, overall result, and evaluation timestamp |
| `RuleResult` | Stable rule ID, pass/fail/error, human explanation, and bounded evidence payload |
| `Alert` | Actionable monitor/run failure with severity, open/resolved state, and notification state |
| `ReviewDecision` | Append-only human classification, rationale, reviewer, evidence identity, and supersession link |
| `AuditEvent` | Security- and approval-relevant action without secret or raw-output leakage |
| `ProductEvent` | Minimal first-party onboarding and product-learning event with allowlisted properties |

### 7.1 Required state transitions

```text
Monitor: draft -> validating -> ready -> baseline_pending -> active -> paused -> archived
Contract: draft -> approved -> retired
Baseline: pending -> approved -> superseded
Run: planned -> queued -> running -> completed | partially_failed | failed | cancelled
Alert: open -> acknowledged -> resolved
```

Behavior-affecting changes never mutate an approved version. They create a new monitor, case, or contract version and require compatibility validation. A provider/model/prompt/configuration change invalidates the active baseline until a replacement is approved.

## 8. Alpha product flow

### 8.1 Entry and onboarding

1. A founder/operator approves a design partner.
2. The system creates a workspace invitation.
3. The user accepts the invite and authenticates.
4. The empty dashboard directs them to `Create your first monitor`.
5. A persisted setup flow guides them through workflow, cases, contract, validation, baseline, and schedule.
6. Progress is derived from completed domain state and remains resumable.

### 8.2 Monitor setup

1. Name the monitor and describe the failure it protects against.
2. Add or select an encrypted provider credential.
3. Choose an allowlisted provider/model and generation configuration.
4. Enter system/user prompt templates and response-format expectations.
5. Add 1–20 representative cases manually or through the versioned JSON import format.
6. Select deterministic templates and configure rules.
7. Test the contract against known-valid and known-invalid fixtures without provider calls.
8. Approve the contract.
9. Preview exact baseline calls and authorize capture.
10. Review baseline health and approve it.
11. Select manual, daily, or weekly replay.

### 8.3 Monitoring and review

1. A due or manual run creates immutable observations.
2. The approved deterministic contract evaluates each observation locally.
3. Operational anomalies remain separate from content failures.
4. A configured contract failure creates or updates an alert.
5. The workspace owner receives an in-app alert and, when configured, one email notification.
6. A reviewer sees exact failed rules and evidence, then classifies the result.
7. If the rule or expectation is wrong, the user creates and validates a new contract version; history is not rewritten.

## 9. Progress summary

| Task | Deliverable | Depends on | Status | Commits |
| --- | --- | --- | --- | --- |
| 1 | Phoenix/Inertia/React/shadcn foundation | — | Complete | `1897937`, `938bbbf` |
| 2 | Minimal public site and design-partner application | 1 | Complete | `0c1811b` |
| 3 | Invite-only accounts, workspaces, memberships, and scope | 1 | Complete | `314e713` |
| 4 | Encrypted provider credentials and validation | 3 | Complete | `c1f0bbf`, `252bb7e`, `9f5b2f6`, `93353bb`, `43be6f6`, `ee8ceca`, `cfdf2cb`, `dfbe096` |
| 5 | Versioned monitor and case domain | 3 | Complete | `1fda0d5`, `bab97d9` |
| 6 | Persisted cold-start monitor setup | 4, 5 | Complete | `c3c9ef5`, `6335d29`, `0db2a94`, `b4c7142` |
| 7 | Generic deterministic contract engine | 5 | Not started | — |
| 8 | Contract authoring, fixture validation, and approval | 6, 7 | Not started | — |
| 9 | Durable capture execution and provider accounting | 4, 5, 7 | Not started | — |
| 10 | Baseline capture, inspection, and approval | 8, 9 | Not started | — |
| 11 | Manual/daily/weekly scheduling and monitor operations | 9, 10 | Not started | — |
| 12 | Run results, evidence, alerts, and operational signals | 9, 10 | Not started | — |
| 13 | Structured review and versioned correction loop | 8, 12 | Not started | — |
| 14 | Onboarding telemetry, notifications, security, and pilot readiness | 2–13 | Not started | — |

## 10. Implementation tasks

### Task 1 — Phoenix/Inertia/React/shadcn foundation

**Status:** Complete

**Objective:** Establish the product frontend and controller boundary without changing spike behavior.

**Checklist:**

- [x] Add and configure the current official `inertia` Phoenix adapter.
- [x] Add React, React DOM, `@inertiajs/react`, TypeScript, and the minimal build dependencies under `assets`.
- [x] Convert the asset entry point to TypeScript/TSX and configure code splitting, extension resolution, and the `@` alias.
- [x] Configure the Inertia plug, root layout, CSRF handling, page title handling, and shared flash props.
- [x] Initialize `assets/components.json` using the current shadcn CLI with React, TSX, Tailwind 4, CSS variables, Lucide, and `@` aliases.
- [x] Use shadcn CLI `info`, documentation, `--dry-run`, and `--diff` before installing or updating registry components.
- [x] Add only the initial primitives: button, card, input, label, textarea, select, alert, badge, progress, skeleton, table, dialog, dropdown menu, and tooltip.
- [x] Define product design tokens in `app.css`; do not add daisyUI or use `@apply`.
- [x] Remove the unused daisyUI dependency and generated integration without disturbing the spike.
- [x] Create an Inertia smoke page and an authenticated-product layout placeholder.
- [x] Add `npm` scripts for type checking, frontend tests, and production build.
- [x] Add controller and frontend smoke tests.

**Acceptance criteria:**

- Phoenix renders an Inertia React page with working navigation, CSRF-protected actions, flash messages, and page titles.
- TypeScript resolves `@/components`, `@/lib`, and page imports.
- Tailwind and installed shadcn primitives render through the supported `app.js` and `app.css` bundles.
- Existing spike and Phoenix tests continue to pass.

**Verification:**

- `npm run typecheck --prefix assets`
- `npm test --prefix assets`
- `mix assets.build`
- Relevant controller tests
- `mix precommit`

**Post-completion dependency review (2026-09-14):** Upgraded the foundation to the latest compatible stable npm and Hex releases in `938bbbf`. The stable pairing remains Elixir `inertia 2.6.2` with `@inertiajs/react 2.3.28`. Revisit Inertia v3 when the Phoenix adapter has a stable `3.x` release; its current `3.0.0-rc5` line implements protocol changes required by the stable JavaScript v3 client.

### Task 2 — Minimal public site and design-partner application

**Status:** Complete

**Objective:** Provide enough public credibility and conversion support for founder-led design-partner recruitment.

**Checklist:**

- [x] Keep the public surface server-rendered and separate from authenticated Inertia routes.
- [x] Build one polished homepage with the deterministic wedge, target workflows, how it works, limitations, and `Apply for design-partner access` CTA.
- [x] Add a short security/data-handling page describing managed replay and customer-provided credentials without making unimplemented compliance claims.
- [x] Add privacy and terms placeholders that are clearly marked for legal review before external use.
- [x] Add a compact design-partner application form and persist submissions.
- [x] Collect only name, work email, company, role, workflow description, current problem, provider, and willingness to participate in recurring feedback.
- [x] Add internal status values for new, contacted, qualified, invited, declined, and withdrawn applications.
- [x] Add canonical metadata, Open Graph metadata, sitemap, and correct robots behavior.
- [x] Ensure authenticated application pages are not indexed.
- [x] Do not add a pricing page, fake free plan, broad blog, or programmatic SEO pages.

**Acceptance criteria:**

- A prospect can understand the product boundary and submit an application.
- Duplicate or invalid submissions are handled safely.
- Public pages are usable without JavaScript and have appropriate metadata.
- No page implies that semantic quality monitoring, public signup, or billing exists.

**Verification:**

- Controller and changeset tests
- Accessibility and responsive browser check
- Metadata, sitemap, and robots assertions
- `mix precommit`

### Task 3 — Invite-only accounts, workspaces, memberships, and scope

**Status:** Complete

**Objective:** Establish secure identity and tenant isolation before storing customer workflows or credentials.

**Checklist:**

- [x] Generate Phoenix 1.8 authentication using binary IDs and preserve generated security behavior.
- [x] Adapt authentication pages to the chosen web boundary.
- [x] Disable public registration and reject uninvited account creation server-side.
- [x] Add workspaces, memberships, and hashed expiring invitation tokens.
- [x] Support only `owner` and `member` roles.
- [x] Add an operator Mix task for creating a workspace invitation.
- [x] Add invitation acceptance, expiration, revocation, and single-use enforcement.
- [x] Build a `Scope` containing user, workspace, and membership.
- [x] Add workspace-slug resolution and membership validation plugs.
- [x] Require the scope in every tenant-owned context function.
- [x] Add shared Inertia props for safe user/workspace identity and flash messages.
- [x] Record invite, membership, login-sensitive, and workspace actions in audit events.

The scope requirement applies to authenticated, tenant-owned operations. The deliberately named
operator provisioning entry point and invitation bearer-token lookup/acceptance are the only Task 3
exceptions because neither begins with an authenticated workspace scope; both establish or verify
that boundary and are covered by separate authorization and audit tests.

**Acceptance criteria:**

- An invited user can authenticate and reach only workspaces where they have membership.
- An uninvited visitor cannot create an account.
- Changing a workspace slug or record ID cannot expose another tenant's records.
- Tests cover revoked/expired tokens and cross-workspace access attempts.

**Verification:**

- Accounts, workspace, invitation, plug, controller, and scope tests
- Explicit cross-tenant authorization tests
- `mix precommit`

### Task 4 — Encrypted provider credentials and validation

**Status:** Complete

**Decision gate:** Resolved 2026-09-14. Use `Cloak.Ecto` with a versioned application keyring and the documented zero-downtime re-encryption sequence. Owners manage credentials; members may view safe metadata and use valid credentials through server-side workflows.

**Objective:** Let a workspace safely store, validate, rotate, and revoke OpenAI and Anthropic credentials.

**Checklist:**

- [x] Review `Cloak.Ecto` and record the selected encryption approach in the decision log.
- [x] Add a runtime-managed encryption key with safe development and test configuration.
- [x] Add provider credential schema, context, lifecycle states, and audit events.
- [x] Encrypt the secret column and keep searchable/display metadata separate.
- [x] Never return decrypted credentials in Inertia props or inspection output.
- [x] Add create, list, validate, rotate, and revoke actions.
- [x] Use the normalized provider boundary for validation.
- [x] Retain returned-model and provider request provenance where available.
- [x] Redact provider authorization headers, request bodies, prompts, contexts, outputs, and encrypted-field query parameters from logs.
- [x] Establish the execution boundary so callers pass only credential IDs and secrets are resolved at call time within workspace scope.
- [x] Add a safe fake provider implementation for automated tests; never call live APIs from the test suite.

**Acceptance criteria:**

- Database values and logs never contain a plaintext provider key.
- Stored credentials cannot be fetched from another workspace.
- Validation failures distinguish authentication, authorization/model access, rate limiting, transport, and provider errors without exposing secrets.
- Rotation supersedes the old secret without rewriting historical run provenance.

**Verification:**

- [x] Encryption-at-rest assertion using direct database reads
- [x] Redaction and cross-tenant tests
- [x] Mocked OpenAI and Anthropic adapter tests
- [x] Manually authorized live smoke test outside the automated suite
- [x] `mix precommit`

### Task 5 — Versioned monitor and case domain

**Status:** Complete

**Design decision:** Use complete append-only monitor/case snapshots with database-enforced content
immutability. Keep monitor name and description as metadata-only fields. Persist incomplete Task 6
setup separately, then promote a valid snapshot. Store exact allowlisted model IDs without aliases or
fallback substitution. See [`docs/monitors/RESEARCH.md`](../docs/monitors/RESEARCH.md).

**Objective:** Create the durable, immutable configuration lineage required for trustworthy comparisons.

**Checklist:**

- [x] Add monitor, monitor version, and case version schemas and contexts.
- [x] Define monitor and configuration state transitions.
- [x] Store prompt templates, frozen context, input variables, response format, generation configuration, provider, and requested model.
- [x] Generate stable fingerprints from all behavior-affecting fields.
- [x] Define which fields are metadata-only and may be edited without a new version.
- [x] Create a new immutable version for every behavior-affecting change.
- [x] Add manual case entry and a documented versioned JSON import schema.
- [x] Enforce initial alpha caps of 1–20 active cases per monitor and bounded payload sizes through configuration.
- [x] Add provider/model allowlists without silently substituting models.
- [x] Reject comparisons and baselines with incompatible fingerprints or provenance.
- [x] Add audit events for monitor version activation, pausing, and archival.

**Acceptance criteria:**

- Approved configuration content cannot be mutated in place.
- Fingerprints change for every behavior-affecting edit and remain stable for metadata-only edits.
- Imported cases produce the same normalized representation as manually entered cases.
- All queries are workspace-scoped.

**Verification:**

- Changeset, fingerprint, state-transition, import, and tenancy tests
- `mix precommit`

### Task 6 — Persisted cold-start monitor setup

**Status:** Complete

**Design decision:** Persist incomplete input in a mutable, workspace-scoped setup draft and promote
only a complete valid configuration into Task 5's immutable version history. Treat credential
selection as operational monitor configuration outside the behavior fingerprint. Derive checklist
progress from persisted validity rather than user-controlled completion flags. See
[`docs/monitor-setup/RESEARCH.md`](../docs/monitor-setup/RESEARCH.md).

**Objective:** Give an invited design partner a resumable guided path from an empty workspace to a contract-ready monitor.

**Checklist:**

- [x] Build the product shell with workspace switcher, monitors navigation, alerts navigation, and account menu.
- [x] Build an empty dashboard with one primary `Create your first monitor` action.
- [x] Implement persisted setup steps for purpose, credential/model, prompt/configuration, and cases.
- [x] Use Inertia form submissions and server changesets as the source of validation truth.
- [x] Preserve drafts and allow the user to leave and resume safely.
- [x] Derive progress from persisted domain state.
- [x] Show what data is stored and what will be sent to the selected provider.
- [x] Show case counts, payload limits, and estimated calls before any live execution.
- [x] Add loading, empty, validation, provider-error, and recovery states.
- [x] Ensure accessible keyboard flow and responsive layouts.
- [x] Record setup-step completion and abandonment as allowlisted product events.

**Acceptance criteria:**

- A new user can create a complete draft monitor without founder database intervention.
- Refreshing or leaving the flow does not lose valid progress.
- No provider call occurs during these steps.
- The next incomplete action is always apparent.

**Verification:**

- Controller and context tests for every step
- Frontend form and state tests
- Browser test covering draft creation and resumption
- `mix precommit`

### Task 7 — Generic deterministic contract engine

**Status:** In progress

**Objective:** Convert the spike's proven deterministic concept into versioned, monitor-specific, explainable product primitives.

**Initial rule primitives:**

- JSON validity and required structure.
- Required JSON path, type, exact value, allowed values, and numeric range/tolerance.
- Normalized classification label from an allowed set.
- Required text/fact alternatives declared by the customer.
- Forbidden text/fact alternatives declared by the customer.
- Required source IDs and bounded citation placement for a documented citation format.
- Required abstention alternatives for explicitly unsupported cases.
- Minimum/maximum length where it is a genuine contract requirement.
- Composable `all`, `any`, and `not` groups with bounded depth.

**Checklist:**

- [ ] Define a versioned machine-readable rule schema with stable rule IDs.
- [ ] Add strict parsing and validation with no atom creation from customer input.
- [ ] Exclude arbitrary executable code and unbounded regular expressions.
- [ ] Port or rewrite only generic spike logic; remove fixture-specific facts and phrases.
- [ ] Return pass, fail, and evaluator-error separately.
- [ ] Produce a concise human explanation and bounded structured evidence for each result.
- [ ] Version the evaluator engine independently from the contract.
- [ ] Separate observations from evaluations so stored outputs can be rescored.
- [ ] Add positive, negative, malformed, boundary, and adversarial fixtures for every primitive.
- [ ] Add held-out cases from domains beyond the original RAG fixtures.
- [ ] Confirm the engine contains no lexical or semantic drift claims.

**Acceptance criteria:**

- Every primitive passes its conformance suite and produces useful evidence.
- The engine is deterministic for the same observation, contract version, and evaluator version.
- Re-evaluation creates a new evaluation record without mutating the observation.
- No product rule contains hard-coded spike facts.

**Verification:**

- Evaluator unit and property-oriented boundary tests
- Approved generic conformance fixtures
- `mix precommit`

### Task 8 — Contract authoring, fixture validation, and approval

**Status:** Not started

**Objective:** Make contract creation understandable enough to test whether customers can define and approve useful expectations.

**Checklist:**

- [ ] Build contract template selection based on workflow type.
- [ ] Build shadcn-based forms for configuring rules without exposing raw internal JSON by default.
- [ ] Provide an advanced read-only or validated JSON view for transparency and support.
- [ ] Let users add known-valid and known-invalid fixture outputs.
- [ ] Evaluate fixtures locally with no provider calls.
- [ ] Show each rule's expected and actual fixture outcome.
- [ ] Block approval when required fixture judgments are missing or contradicted.
- [ ] Require explicit approval by a workspace owner.
- [ ] Seal the approved contract version and fingerprint it.
- [ ] Make edits create a new draft version.
- [ ] Record which suggested templates were accepted, edited, or removed.
- [ ] Keep in-product LLM contract drafting out of the alpha; Codex/founder assistance remains a concierge process until repeated needs justify automation.

**Acceptance criteria:**

- A customer can understand why a fixture passes or fails before spending provider calls.
- Approval is attributable and tied to exact contract and fixture bytes.
- An approved contract cannot be edited in place.
- The product captures where founder assistance was required.

**Verification:**

- Contract lifecycle and approval authorization tests
- Frontend rule-form and fixture-result tests
- Browser test covering draft, validation failure, correction, and approval
- `mix precommit`

### Task 9 — Durable capture execution and provider accounting

**Status:** Not started

**Objective:** Replace CLI-only and in-memory capture with one durable execution path shared by baseline, manual, and scheduled runs.

**Checklist:**

- [ ] Add Oban and generate its migration through the supported Mix task.
- [ ] Configure capture and scheduler queues plus manual testing mode.
- [ ] Add capture run, observation, evaluation, and rule-result schemas.
- [ ] Create planned runs with immutable provider, configuration, case, contract, and call-budget references.
- [ ] Enqueue jobs with idempotency and uniqueness by run identity.
- [ ] Resolve credentials at execution time without putting secrets in job arguments.
- [ ] Apply bounded concurrency and back-pressure for provider calls.
- [ ] Count retries against the maximum call budget.
- [ ] Preserve requested and returned model, completion state, usage, latency, safe provider request ID, and failure category.
- [ ] Normalize and store only provider response fields required for evidence and operations.
- [ ] Make cancellation stop the scheduling of new calls and preserve completed observations.
- [ ] Evaluate successful observations locally under the exact approved contract version.
- [ ] Recover safely from worker restarts without duplicating completed calls where the provider boundary permits.

**Acceptance criteria:**

- Baseline, manual, and scheduled captures use the same orchestration path.
- A run cannot exceed its call cap, including retries.
- Duplicate worker execution does not duplicate completed observations or spend silently.
- Partial provider failure produces an honest terminal state and retained evidence.

**Verification:**

- Oban worker tests using manual test mode
- Retry, uniqueness, cancellation, restart, partial-failure, and cap tests
- Mocked provider accounting tests
- `mix precommit`

### Task 10 — Baseline capture, inspection, and approval

**Status:** Not started

**Objective:** Make the first live spend explicit and create an immutable compatible reference for the monitor.

**Checklist:**

- [ ] Add a preflight that validates credential state, model access, monitor readiness, contract approval, cases, and call caps.
- [ ] Show exact case count, samples per case, maximum requests, retry policy, and available usage estimate.
- [ ] Require explicit user authorization before enqueueing the baseline.
- [ ] Support a bounded alpha sample count with a conservative default.
- [ ] Stream or poll durable progress without relying on an in-memory browser process.
- [ ] Display successful, incomplete, failed, and unknown completions separately.
- [ ] Surface returned-model mismatches as operational anomalies even when calls succeed.
- [ ] Require all zero-tolerance contract conditions before normal approval; exceptional acceptance requires an explicit recorded rationale.
- [ ] Seal approved baseline membership and provenance.
- [ ] Invalidate compatibility when behavior-affecting configuration changes.

**Acceptance criteria:**

- No provider spend occurs without an exact preview and explicit authorization.
- A baseline can be approved only under a compatible approved contract.
- The user can inspect every observation and deterministic result before approval.
- Approved membership and provenance cannot be silently rewritten.

**Verification:**

- Preflight, authorization, compatibility, mismatch, and approval tests
- Browser test with fake provider from preview through approval
- One manually authorized live provider smoke test
- `mix precommit`

### Task 11 — Manual/daily/weekly scheduling and monitor operations

**Status:** Not started

**Objective:** Deliver the continuous part of the wedge with a deliberately small scheduling surface.

**Checklist:**

- [ ] Support `Run now`, `Daily`, `Weekly`, `Pause`, and `Resume`.
- [ ] Store cadence and the next scheduled UTC time on the monitor.
- [ ] Add a small recurring Oban dispatcher that enqueues due monitors.
- [ ] Lock or atomically claim due monitors to prevent duplicate scheduling.
- [ ] Add unique scheduled-run identity by monitor and intended execution time.
- [ ] Prevent overlapping runs for the same monitor.
- [ ] Recalculate `next_run_at` only after an atomic scheduling decision.
- [ ] Require an approved compatible baseline before activation.
- [ ] Show last run, next run, cadence, monitor state, and unresolved alert count.
- [ ] Pause automatically on revoked credentials, incompatible versions, repeated authentication failures, or exhausted workspace guardrails.
- [ ] Record schedule and lifecycle audit events.

**Acceptance criteria:**

- Manual, daily, and weekly runs enqueue through the same capture pipeline.
- Restarts and multiple nodes cannot silently duplicate a scheduled window.
- Paused or incompatible monitors do not call providers.
- The UI accurately represents the durable database state.

**Verification:**

- Dispatcher, uniqueness, overlap, pause/resume, and next-run tests
- Time-controlled tests without `Process.sleep/1`
- Browser test for schedule activation and pause
- `mix precommit`

### Task 12 — Run results, evidence, alerts, and operational signals

**Status:** Not started

**Objective:** Let users understand exactly what happened and why a result is actionable.

**Checklist:**

- [ ] Build monitor overview and run-history pages.
- [ ] Build a run detail page with planned/actual calls, completion counts, latency, tokens, and provider failures.
- [ ] Show each case, observation, evaluation, and rule result with bounded evidence.
- [ ] Clearly separate contract failures from provider/latency/usage/model anomalies.
- [ ] Support critical and warning rule severities plus a small explicit alert policy.
- [ ] Create alerts idempotently from actionable run outcomes.
- [ ] Add open, acknowledged, and resolved alert states.
- [ ] Show baseline and current provenance together and reject incompatible comparisons.
- [ ] Avoid unexplained aggregate quality scores.
- [ ] Add safe empty, loading, partial failure, stale configuration, and no-alert states.
- [ ] Ensure long prompts, contexts, and outputs cannot break layout or inject executable content.

**Acceptance criteria:**

- A reviewer can explain every alert from the displayed rule, evidence, observation, and provenance.
- Operational anomalies are never described as content degradation.
- Reloading or retrying result pages does not duplicate alerts.
- Sensitive values are redacted in UI and exported diagnostic data.

**Verification:**

- Result presenter, alert lifecycle, provenance, and escaping tests
- Frontend evidence and responsive-layout tests
- Browser test from completed fake run to alert inspection
- `mix precommit`

### Task 13 — Structured review and versioned correction loop

**Status:** Not started

**Objective:** Capture design-partner judgment as governed evidence and make correction safe.

**Review classifications:**

- Correct pass.
- Confirmed regression.
- Acceptable variation / false alert.
- Contract needs revision.
- Test case or baseline problem.
- Passed but should have failed.
- Unsure / requires review.
- Operational/provider anomaly.

**Checklist:**

- [ ] Add append-only review decisions tied to exact run, observation, evaluation, rule, contract, and baseline identities as applicable.
- [ ] Require reviewer identity, classification, and optional rationale.
- [ ] Allow a later decision to supersede, not overwrite, an earlier decision.
- [ ] Add alert acknowledgment and resolution actions with authorization.
- [ ] Add `passed but should have failed` entry points for false-negative discovery.
- [ ] Record whether the review caused a prompt, case, contract, provider, or operational action.
- [ ] Start a contract-revision flow from a review without mutating history.
- [ ] Rescore stored observations under a newly approved contract version before activation.
- [ ] Require a new baseline only when compatibility rules say the interpretation or monitored behavior changed materially.
- [ ] Expose review counts and disagreement without calling them model accuracy until sample sizes support it.

**Acceptance criteria:**

- Every judgment remains attributable to exact evidence.
- History remains reproducible after a contract correction.
- The product captures false positives and false negatives, not merely thumbs up/down.
- Workspace members cannot approve or resolve actions reserved for owners.

**Verification:**

- Review append/supersession, authorization, rescore, and history tests
- Browser test covering false alert, missed regression, and contract revision
- `mix precommit`

### Task 14 — Onboarding telemetry, notifications, security, and pilot readiness

**Status:** Not started

**Decision gates before external data:**

- Select the transactional email provider.
- Approve raw prompt/context/output retention and deletion behavior.
- Approve the credential master-key and rotation procedure.
- Approve alpha usage/call caps and supported model allowlists.

**Objective:** Make the complete local product safe and observable enough for controlled external use, without deploying it yet.

**Checklist:**

- [ ] Add a derived onboarding checklist for credential, workflow, cases, contract, baseline, and schedule.
- [ ] Add allowlisted product events for time-to-first-monitor, step abandonment, founder assistance, baseline approval, schedule activation, alert review, and action taken.
- [ ] Keep product events free of prompts, contexts, outputs, credentials, and arbitrary user text.
- [ ] Add one actionable-alert email path with deduplication and preference control.
- [ ] Use the local Swoosh adapter until a transactional provider is selected.
- [ ] Add workspace-level run and call caps with clear errors.
- [ ] Add retention, customer deletion, credential revocation, and workspace closure workflows.
- [ ] Verify logs, telemetry, exceptions, job arguments, and audit events against a sensitive-data allowlist.
- [ ] Add rate limiting for login, invitations, credential validation, and run authorization.
- [ ] Add backup/restore and encryption-key rotation notes for eventual Fly.io deployment.
- [ ] Add an operator runbook for invitations, failed jobs, provider incidents, data deletion, and pilot support.
- [ ] Add end-to-end tests for the complete fake-provider journey.
- [ ] Conduct separate manually authorized OpenAI and Anthropic smoke tests.
- [ ] Record pilot limits and known limitations in customer-visible alpha documentation.
- [ ] Produce a deployment-readiness checklist without creating Fly.io resources.

**Acceptance criteria:**

- A fresh invited user can complete the entire fake-provider flow without database intervention.
- The operator can identify where onboarding stalled without reading customer content.
- Alert email is sent once for an actionable alert and links to authorized evidence.
- Customer data and credentials can be removed through a documented, tested path.
- The app passes the security, tenancy, call-budget, and end-to-end pilot gates.
- Fly.io deployment remains a separate, explicitly authorized follow-up.

**Verification:**

- Full backend and frontend suites
- End-to-end private-alpha journey
- Redaction, deletion, rate-limit, notification-deduplication, and cross-tenant suites
- Manually authorized provider smoke tests
- `mix precommit`

## 11. Cross-cutting testing strategy

### 11.1 Backend

- Context and schema tests for state transitions and invariants.
- `DataCase` tests for constraints, transactions, immutable records, and tenant scoping.
- `ConnCase` tests for authentication, authorization, Inertia props, validation, and redirects.
- Provider behaviour tests with deterministic fakes for success, incomplete output, authentication failure, rate limiting, timeout, malformed response, and returned-model mismatch.
- Oban manual-mode tests for uniqueness, retries, cancellation, partial completion, and scheduling.
- Evaluator conformance fixtures separated from their held-out verification cases.

### 11.2 Frontend

- TypeScript type checking.
- Component tests for complex forms, rule evidence, state transitions, and error recovery.
- Do not over-test shadcn primitives; test Silent Regression behavior composed from them.
- Browser tests for invitation, setup resumption, contract approval, baseline authorization, scheduling, alert review, and correction.

### 11.3 Live provider tests

- Never execute live provider calls in automated tests.
- Every live smoke command must preview provider, model, configuration, cases, samples, retries, and maximum calls.
- Require explicit authorization and a hard maximum-call cap.
- Record planned and actual calls plus returned-model provenance.

## 12. Product-learning measurements

The alpha is successful only if it produces customer evidence, not merely working software.

| Question | Measurement |
| --- | --- |
| Can a partner activate? | Invitation accepted through approved baseline and active schedule |
| How much assistance is required? | Founder interventions by setup step and reason |
| Can customers define contracts? | Rules created, templates accepted/edited/rejected, validation iterations |
| Is monitoring useful? | Reviewed alerts, confirmed regressions, actions taken, time to decision |
| Is it trustworthy? | False alerts, missed regressions, unsure reviews, evaluator disputes |
| Does it recur? | Active monitors and completed scheduled runs over successive periods |
| Is the architecture acceptable? | Credential/data/security objections and blocked pilots |
| Is there economic intent? | Paid pilot, procurement action, budget owner involvement, or explicit continuation commitment |

Proposed product-validation gate before broader productization:

- At least three design partners provide real workflows and representative cases.
- The same core requirements recur across multiple partners.
- At least two partners keep a monitor active across repeated scheduled runs.
- Customers can approve or revise useful contracts without the founder inventing every rule.
- Alerts cause concrete review and at least one operational or product action.
- False-alert and missed-regression feedback is acceptable to the participating partners.
- At least one partner demonstrates economic commitment.

## 13. Definition of private-alpha ready

The product is ready for the first external design partner only when:

- [ ] Tasks 1–14 are complete.
- [ ] Public registration and all billing routes are absent.
- [ ] Tenant isolation has explicit adversarial tests.
- [ ] Provider credentials are encrypted, redacted, revocable, and never returned to the browser.
- [ ] The full onboarding and monitoring loop passes with the fake provider.
- [ ] OpenAI and Anthropic smoke tests pass under explicit call caps.
- [ ] Every behavior-affecting edit produces a compatible new version or invalidates the baseline.
- [ ] Scheduled work is durable, bounded, unique, and recoverable.
- [ ] Alerts show deterministic evidence and do not claim semantic understanding.
- [ ] Result feedback records false alerts and missed regressions.
- [ ] Customer-visible data use, retention, limitations, and deletion behavior are documented.
- [ ] The operator runbook and deployment-readiness checklist are complete.
- [ ] The user explicitly authorizes deployment and the first design-partner invitation.

## 14. Risks and stop conditions

| Risk | Early evidence | Response |
| --- | --- | --- |
| Contract authoring is too difficult | Founder writes nearly every rule | Narrow templates further; do not hide the problem with generated rules |
| Deterministic checks are too brittle | Frequent acceptable-variation reviews | Improve monitor-specific contracts and fixtures; do not introduce an unvalidated semantic judge |
| Hosted replay is unacceptable | Prospects refuse credentials or data transfer | Reassess the no-SDK hosted boundary before building enterprise features |
| Wedge is only a feature | Partners prefer existing CI/eval tools | Identify a sharper managed-workflow advantage or stop expanding scope |
| Provider cost is surprising | Runs approach caps or partners hesitate to schedule | Reduce defaults, improve previews, and require explicit budgets |
| Duplicate execution | Planned/actual counts diverge or scheduled windows overlap | Stop scheduling until idempotency is corrected |
| Cross-tenant exposure | Any authorization test or audit fails | Block all external access until fixed and reviewed |
| Unique requests dominate | Every partner needs different primitives or integrations | Do not turn the alpha into custom consulting software without an explicit business decision |

## 15. Decision log

| Date | Decision | Rationale | Affected tasks |
| --- | --- | --- | --- |
| 2026-09-13 | Build a deterministic-only private alpha alongside design-partner recruitment | The spike validated a narrow technical wedge but not self-service adoption or market demand | All |
| 2026-09-13 | Omit Stripe and plan selection | A free subscription validates no payment behavior and adds unrelated state and failure modes | 2, 3, 14 |
| 2026-09-13 | Use invite-only workspace access | Customer prompts, outputs, and credentials require identity and tenant isolation while the product remains controlled | 3 onward |
| 2026-09-13 | Use React/Inertia/shadcn for the product and a small server-rendered public surface | Matches the useful `high_school` boundary while keeping public pages simple and indexable | 1, 2 |
| 2026-09-13 | Use durable PostgreSQL-backed jobs for captures and schedules | Scheduled provider spend must survive restarts and prevent duplicates | 9–11 |
| 2026-09-13 | Keep direct `Req` adapters initially | The spike already proves provenance-aware provider calls; ReqLLM remains an evidence-based later decision | 4, 9 |
| 2026-09-14 | Approve the implementation plan and begin Task 1 | The user approved the scoped sequence and the hybrid public/product frontend boundary recorded in the plan | 1 onward |
| 2026-09-14 | Use latest compatible stable dependencies and defer Inertia v3 | The JavaScript v3 client changes the initial-page protocol, while the matching Phoenix adapter is still on `3.0.0-rc5`; use stable `inertia 2.6.2` with the latest v2 React client until both sides are stable | 1 onward |
| 2026-09-14 | Make invitation acceptance the only account-creation boundary | The private alpha needs generated authentication security without exposing public registration; accepting a valid locked invitation atomically creates or confirms the identity and membership | 3 onward |
| 2026-09-14 | Make `Workspace` the default Phoenix generator scope | Future tenant-owned contexts should generate `workspace_id` boundaries and `/app/:workspace_slug` routes by default; the user-only scope remains available for identity operations | 3 onward |
| 2026-09-14 | Encrypt provider credentials with Cloak.Ecto and restrict lifecycle management to owners | AES-256-GCM with a runtime application keyring is the smallest appropriate private-alpha boundary and supports versioned rotation; members may use valid credentials without gaining create, rotate, revoke, or plaintext access | 4, 9, 14 |
| 2026-09-14 | Use complete append-only monitor snapshots with behavior-based compatibility | Database triggers protect executable and case content; monitor metadata remains editable, while case display-only successors retain the same fingerprint and baseline compatibility. Owners and members may collaborate on monitor definitions | 5 onward |
| 2026-09-14 | Persist cold-start input outside immutable history and promote only when complete | A mutable workspace-scoped setup draft supports refresh/resume while Task 5 remains append-only; credential identity is operational configuration, so rotation does not silently change the behavior fingerprint | 6, 9–11 |
| 2026-09-15 | Use a bounded declarative contract DSL with separately versioned pure evaluations | Strict versioned parsing, fixed normalization/citation syntax, RFC 6901 paths, and hard resource limits make deterministic judgments explainable and safe; Task 8 owns approval persistence and Task 9 owns durable execution records | 7–9, 12 |

## 16. Session log

### 2026-09-13 — Planning

- Created the private-alpha implementation sequence and progress tracker.
- Inspected the existing Silent Regression Phoenix/spike structure.
- Inspected the local `high_school` reference for Inertia, React, shadcn, workspace scope, onboarding, and Oban patterns.
- Scoped out Stripe, public signup, semantic evaluation, broad SEO, and immediate Fly.io deployment.
- No product implementation has started.

### 2026-09-14 — Task 1 started

- The user approved the implementation plan.
- Marked the Phoenix/Inertia/React/shadcn foundation as in progress.

### 2026-09-14 — Task 1 complete

- Added the Phoenix Inertia adapter and established a server-rendered public boundary plus a React/Inertia product boundary at `/app`.
- Added the TypeScript toolchain, frontend test runner, Tailwind 4 design tokens, and the reviewed shadcn primitive set.
- Added a product-shell smoke page with explicit disabled states for product capabilities scheduled in later tasks.
- Removed daisyUI and retained the existing spike behavior and test suite.
- Verified `npm run check`, `mix assets.build`, focused controller tests, and `mix precommit` with 252 passing Elixir tests.
- Verified a real `GET /app` returned HTTP 200 with CSRF/XSRF tokens, the `Dashboard` Inertia payload, title props, and supported asset references.
- Implementation commit: `1897937`.

### 2026-09-14 — Task 1 dependency currency follow-up

- Audited direct npm and Hex dependencies against their registries rather than treating `high_school` as a version source.
- Upgraded React and React DOM to `19.3.0`, Lucide React to `1.46.0`, Tailwind Merge to `3.7.0`, and `tw-animate-css` to `1.4.0`.
- Upgraded Phoenix to `1.8.14`, DNS Cluster to `0.3.0`, and Phoenix LiveDashboard to `0.9.1`; Hex reports all direct dependencies current.
- Confirmed Elixir `inertia 2.6.2` is the latest stable Phoenix adapter. Upgraded its matching v2 React client to `2.3.28` and deliberately deferred JavaScript v3 while the Phoenix `3.x` adapter remains a release candidate.
- Verified a clean `npm ci` with zero reported vulnerabilities, frontend type checking and tests, the production asset build, 252 Elixir tests through `mix precommit`, a full-page HTTP 200, and an Inertia-versioned XHR HTTP 200 with the expected `Dashboard` payload.
- Dependency commit: `938bbbf`.

### 2026-09-14 — Task 2 started

- Began the server-rendered public site and persisted design-partner application.
- Kept the application form outside account creation and retained the separate React/Inertia product boundary.
- Chose privacy-preserving idempotent handling for case-insensitive duplicate email submissions; no application-management UI is included in this task.

### 2026-09-14 — Task 2 complete

- Added the polished server-rendered homepage, security page, legal-review privacy and terms placeholders, and a selective design-partner application flow without adding public signup, pricing, billing, or unsupported semantic-monitoring claims.
- Persisted the eight approved application fields with database-enforced provider/status values, case-insensitive email uniqueness, six internal lifecycle states, validation, and privacy-preserving duplicate submission behavior.
- Added canonical, description, Open Graph, and robots metadata plus dynamic sitemap and robots responses; `/app` and the application confirmation page are explicitly non-indexable.
- Fixed the Phoenix development live-reload event contract after the browser pass exposed a console exception on server-rendered navigation.
- Verified 266 Elixir tests through `mix precommit`, frontend type checking and tests, the production asset build, desktop and mobile layouts, accessible browser control names, a clean console, and a real form submission through persistence and redirect. Removed the temporary QA record and browser artifacts afterward.
- Implementation commit: `0c1811b`.

### 2026-09-14 — Task 3 started

- Audited Tasks 1–2 against their acceptance criteria and confirmed a clean implementation baseline; legal review of the placeholder policies remains an intentional pre-pilot gate rather than a Task 3 blocker.
- Selected Phoenix 1.8 generated controller authentication with binary IDs as the security base, to be adapted to the existing React/Inertia product boundary.
- Account creation will occur only while atomically accepting a valid hashed invitation; public registration remains absent at both the routing and context boundaries.
- Workspace routes will use `/app/:workspace_slug/...` and require a scope containing the authenticated user, verified workspace, and membership.

### 2026-09-14 — Task 3 complete

- Added Phoenix-generated controller authentication with binary IDs, retained the generated session, magic-link, password, sudo-mode, and token-expiration behavior, and adapted every user-facing authentication screen to React/Inertia.
- Removed public registration routes and context entry points. A valid, locked, expiring invitation is now the only account-creation path; acceptance creates or confirms the user and membership atomically and consumes the token exactly once.
- Added workspaces, `owner`/`member` memberships, hashed invitation tokens, revocation and expiration enforcement, content-free audit events, and the `mix silent_regression.invite` operator command.
- Added `/app/:workspace_slug` tenant resolution with indistinguishable 404 responses for unknown and unauthorized workspaces, safe shared Inertia identity props, and a verified `Scope` containing user, workspace, and membership.
- Made `Workspace` the default Phoenix generator scope so later tenant-owned schemas use `workspace_id` and slug-scoped routes instead of accidentally defaulting to user ownership.
- A real browser pass exposed and fixed a foundation-level CSRF integration gap by configuring Axios to send Phoenix's `x-csrf-token` header for all Inertia mutations; a frontend regression test now protects that contract.
- Verified clean development migrations, 367 Elixir tests through `mix precommit`, frontend type checking and two frontend tests, the production asset build, invitation acceptance and authenticated redirect, consumed-link rejection, enumeration-safe login behavior, mobile login layout, and clean consoles on successful pages. Temporary QA records and browser artifacts were removed.
- Implementation commit: `314e713`.

### 2026-09-14 — Task 4 started

- Began the required encryption and key-rotation decision gate before adding a credential schema or
  accepting any customer provider key.
- Compared Cloak.Ecto application-level encryption, custom Erlang crypto, external KMS/Vault envelope
  encryption, PostgreSQL `pgcrypto`, and per-credential Fly secrets against the private-alpha threat
  model and eventual Fly.io deployment.
- Recorded the research and provisional recommendation in
  [`docs/provider-credentials/RESEARCH.md`](../docs/provider-credentials/RESEARCH.md). No encryption
  library or credential persistence has been added while the decision remains pending.

### 2026-09-14 — Task 4 security design approved

- Approved `Cloak.Ecto` with AES-256-GCM, a versioned application keyring, and runtime production key
  material supplied through Fly secrets.
- Approved owners-only create, validate, rotate, and revoke operations. Members may view safe
  metadata and use valid credentials through future server-side monitor execution, but they cannot
  retrieve plaintext or administer credential lifecycle.
- Kept provider-credential rotation separate from application-master-key re-encryption.

### 2026-09-14 — Task 4 implementation complete; live smoke pending

- Added `Cloak.Ecto` AES-256-GCM encryption with a supervised, versioned vault. Development and test
  use explicit environment-only keys; production requires a Base64-encoded 32-byte runtime secret.
- Added workspace-scoped OpenAI and Anthropic credential records with safe metadata projections,
  pending/valid/invalid/revoked/superseded lifecycle states, append-only audit events, and preserved
  rotation lineage.
- Added normalized OpenAI and Anthropic validation adapters that make exactly one non-generative
  Models API request, retain safe request/model provenance, distinguish actionable failure classes,
  and never expose provider bodies or authorization data.
- Added owner-only create, validate, rotate, and revoke routes and a responsive Inertia credential
  page. Members receive safe status and provenance metadata without mutation controls or plaintext.
- A real owner/member browser pass verified creation, suffix-only display, rotation, supersession,
  revocation, member read-only behavior, mobile layout, and clean consoles. It also exposed two
  plaintext logging surfaces: Phoenix request parameters and Ecto pre-encryption query parameters.
  Both are now suppressed and covered by regression tests.
- Verified 396 Elixir tests through `mix precommit`, frontend type checking, three frontend test files
  with four passing tests, the production asset build, direct database ciphertext, and disposable
  QA-data cleanup. No automated test contacted a live provider.
- The final manually authorized live validation remains pending. Task 4 stays `In progress` until an
  owner validates an intentionally supplied OpenAI or Anthropic credential through the product UI.
- Implementation commits: `c1f0bbf`, `252bb7e`, `9f5b2f6`, `93353bb`, `43be6f6`, `ee8ceca`, and
  `cfdf2cb`.

### 2026-09-14 — Task 4 complete

- Completed manually authorized validation through the product UI with both OpenAI and Anthropic.
- Confirmed from safe persisted metadata that OpenAI validation succeeded in one request and retained
  returned-model and provider-request provenance.
- An initial Anthropic authentication failure was safely categorized without exposing the credential;
  rotating the credential created a new identity, preserved the failed record as superseded, and the
  replacement then validated successfully in one request with model and request provenance.
- Marked Task 4 complete after the live gate passed. Task 5, the versioned monitor and case domain, is
  now the next implementation task.

### 2026-09-14 — Task 5 started

- Selected complete append-only configuration and case snapshots instead of mutable sealed drafts or
  event sourcing. PostgreSQL will enforce content immutability in addition to the context API.
- Defined monitor name and description as the only metadata-only fields. Provider/model, prompts,
  response format, generation configuration, case inputs/context, and active-case membership are
  behavior-affecting.
- Kept partial onboarding state out of executable history; Task 6 will persist setup separately and
  promote only a complete valid snapshot.
- Kept the private-alpha model catalog intentionally narrow and aligned with the approved spike pairs:
  `gpt-5.6-luna`, `gpt-5.6-sol`, `claude-haiku-4-5-20251001`, and `claude-sonnet-5`.
- Recorded the detailed design, limits, import boundary, compatibility contract, risks, and primary
  references in [`docs/monitors/RESEARCH.md`](../docs/monitors/RESEARCH.md).

### 2026-09-14 — Task 5 complete

- Added workspace-scoped monitor identities plus complete append-only monitor and case snapshots.
  Owners and members may collaborate on monitor definitions; archived monitors reject new versions.
- Added PostgreSQL constraints and triggers that reject in-place configuration or case-content
  updates while preserving lifecycle transitions and later user anonymization.
- Added canonical SHA-256 fingerprints for provider/model, prompts, response format, generation
  configuration, active case membership, variables, and frozen context. Monitor name/description and
  case display name/order remain metadata-only.
- Added exact OpenAI and Anthropic allowlists, explicit payload/case bounds, normalized manual entry,
  and the documented `case-import-v1.schema.json` boundary. Unknown fields and silent model
  substitutions are rejected.
- Added transactional candidate creation, monotonic lineage, activation, supersession, monitor state
  transitions, content-free lifecycle audits, and strict provenance compatibility with explicit
  mismatch reasons.
- Fixed a final review edge case so exact no-op saves are rejected while metadata-only case
  successors can remain compatible without mutating history.
- Verified 18 focused monitor-domain tests and 414 total tests through `mix precommit`.
- Implementation commits: `1fda0d5` and `bab97d9`.

### 2026-09-14 — Tasks 1–5 audit and Task 6 started

- Rechecked every completed task against its acceptance criteria and the dependencies needed by the
  cold-start flow. No completed-task criterion needs to be reopened.
- Reverified frontend type checking, four frontend tests, and the production asset build. The latest
  backend `mix precommit` remains green with 414 tests.
- Confirmed the stale foundation dashboard, disabled monitor navigation, pending local Task 5
  development migration, and absent setup draft/credential association are deliberate Task 6 work,
  not missed earlier deliverables.
- Selected a separate mutable setup draft, derived progress, explicit safe product-learning events,
  and atomic promotion into an immutable monitor version. Recorded the detailed review and design in
  [`docs/monitor-setup/RESEARCH.md`](../docs/monitor-setup/RESEARCH.md).

### 2026-09-15 — Task 6 complete

- Added a workspace-scoped mutable setup draft for incomplete input, an operational credential
  association outside the behavior fingerprint, derived step progress, and an atomic completion
  transaction that promotes only valid content into Task 5's immutable monitor-version history.
- Added allowlisted, content-free product events for setup start, first completion of each valid
  step, save-and-exit, and final completion. Prompt, context, variables, import content, and outputs
  are filtered from Phoenix request logs.
- Added the authenticated monitor dashboard and cold-start flow for purpose, exact credential/model,
  prompt/generation configuration, manual or versioned-JSON cases, and final review. Every route is
  inside `/app/:workspace_slug` with the authenticated and verified-workspace pipelines so tenant
  membership is resolved before a setup controller runs and cross-workspace records remain 404.
- Added desktop and mobile workspace/account navigation, persisted draft recovery, server-backed
  validation, provider-credential recovery, explicit stored-versus-sent explanations, payload and
  case limits, and a provider-call preview that states setup makes zero calls.
- A real browser pass covered login, empty-state creation, save-and-exit, full refresh, resume to the
  derived next step, completion, immutable review, and a 390-pixel mobile viewport. It exposed and
  fixed generic empty optional-setting normalization, an HTML Unicode-Sets pattern incompatibility,
  premature connection submission, and unnamed compact step navigation. The final browser console
  had no errors or warnings.
- Applied the pending Task 5 and Task 6 development migrations, completed the full flow with an
  existing validated Anthropic credential without making a provider call, and removed the disposable
  monitor and its seven setup events after verification.
- Verified 18 focused setup tests, 10 frontend tests with TypeScript checking, the production asset
  build, and 432 total Elixir tests through `mix precommit`.
- Implementation commits: `c3c9ef5`, `6335d29`, `0db2a94`, and `b4c7142`.

### 2026-09-15 — Task 7 started

- Defined Task 7 as the product-owned, pure contract/evaluation boundary. Task 8 will persist and
  approve contracts and fixtures; Task 9 will persist capture observations, evaluations, and rule
  results without changing the engine semantics.
- Selected a bounded version-1 declarative DSL with stable rule IDs, RFC 6901 JSON Pointers, fixed
  literal-text normalization, exact bracketed citation IDs, no customer-authored regex or executable
  code, and explicit pass/fail/evaluator-error outcomes.
- Recorded the contract envelope, primitives, safety limits, evidence rules, rescoring boundary,
  deferred needs, and primary references in
  [`docs/contracts/RESEARCH.md`](../docs/contracts/RESEARCH.md).
- Received human approval for all 31 generic conformance judgments and promoted the conformance
  fixture set from candidate to approved. The separate held-out fixture outcomes remain unevaluated
  pending human approval of their labels.

## 17. References

- [Feasibility spike implementation plan](implementation_plan.md)
- [Productization gaps and future needs](productization_plan.md)
- [Deferred semantic-layer plan](semantic_layer_plan.md)
- [Phoenix 1.8 authentication generator](https://phoenix.hexdocs.pm/Mix.Tasks.Phx.Gen.Auth.html)
- [Phoenix 1.8 scopes](https://phoenix.hexdocs.pm/authn_authz.html)
- [Inertia Phoenix adapter](https://inertia.hexdocs.pm/readme.html)
- [Inertia v3 upgrade guide](https://inertiajs.com/docs/v3/getting-started/upgrade-guide)
- [Phoenix adapter Inertia v3 compatibility tracking](https://github.com/inertiajs/inertia-phoenix/issues/67)
- [Oban periodic jobs](https://oban.hexdocs.pm/periodic_jobs.html)
- [shadcn/ui installation](https://ui.shadcn.com/docs/installation)
- [Cloak.Ecto encrypted fields](https://hexdocs.pm/cloak_ecto/readme.html)
