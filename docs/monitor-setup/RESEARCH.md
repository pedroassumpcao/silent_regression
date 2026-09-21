# Persisted Monitor Setup Research

> Historical Task 6 research. The founder approved the follow-up [UX assessment](UX_ASSESSMENT.md)
> on 2026-09-21. Its implementation is tracked in [IMPLEMENTATION.md](IMPLEMENTATION.md) and
> [PROGRESS.md](PROGRESS.md); completed historical task evidence below is preserved.

## Overview

Task 6 turns the authenticated product shell and Task 5 monitor domain into a resumable cold-start
flow. It persists incomplete user input separately from immutable executable history, creates no
provider calls, and promotes only a complete valid setup into a `MonitorVersion` snapshot.

## Tasks 1–5 readiness audit

The implementation was checked against the authoritative private-alpha plan before Task 6 began.

| Foundation | Evidence reviewed | Result for Task 6 |
| --- | --- | --- |
| Phoenix/Inertia/React/shadcn | Hybrid route boundary, shared props, CSRF integration, page resolution, TypeScript tests, and production asset build | Ready; the smoke dashboard is intentionally replaced in Task 6 |
| Public design-partner surface | Server-rendered routes, persisted application, metadata/robots coverage, and explicit legal-review placeholders | Ready; legal review remains a pre-pilot gate, not a setup blocker |
| Invite-only tenancy | Authentication routes, workspace resolution, `Scope`, membership tests, and indistinguishable cross-workspace 404s | Ready; every setup route stays under the authenticated workspace scope |
| Provider credentials | Encrypted storage, safe metadata projection, owner/member authorization, validation provenance, and completed OpenAI/Anthropic live smoke | Ready; setup may select only a valid same-workspace credential |
| Versioned monitor domain | Workspace-scoped context, append-only snapshots, database triggers, fingerprints, import normalization, lifecycle, and compatibility tests | Ready; incomplete input must not be written into version history |

The audit reran frontend type checking, all frontend tests, and the production asset build. The most
recent backend `mix precommit` run passed 414 tests. The Task 5 development migration remains pending
locally and will be applied together with the Task 6 migration before browser verification.

No completed-task acceptance criterion needs to be reopened. Three visible omissions are deliberate
Task 6 work rather than regressions: the dashboard still describes the foundation spike, monitor
navigation is disabled, and no persisted setup draft or credential selection exists yet.

## Product boundary

- A new workspace starts with an honest empty dashboard and one primary monitor-creation action.
- Creating the monitor persists its stable name and description plus a separate mutable setup draft.
- Setup has four persisted steps: purpose, credential/model, prompt/configuration, and cases.
- Progress is computed from valid persisted domain state; users do not check off arbitrary booleans.
- A review screen explains stored data, provider-bound data, case counts, limits, and future call
  implications before promotion.
- Completing setup creates an immutable candidate `MonitorVersion`; it does not validate prompts,
  call a provider, create a contract, or capture a baseline.
- The next unavailable product action is stated honestly as deterministic contract configuration.

## Persistence approach

### Approaches considered

1. **Write partial values directly into `MonitorVersion`.** Rejected because it weakens the complete,
   append-only provenance boundary established in Task 5.
2. **Keep setup only in React/Inertia history state.** Rejected because browser refreshes, device
   changes, or a long design-partner interview would lose valid work.
3. **Persist a mutable setup draft and promote a complete snapshot (selected).** This preserves
   resumability without admitting partial executable history.

The setup draft uses ordinary columns for the provider and prompt fields plus one bounded JSONB map
for normalized cases. Ecto documents embedded/map storage as appropriate for intermediate UI state;
the product reuses Task 5's `CaseInput` normalizer rather than creating a second case-validation
language.

## Credential association

The selected provider credential is operational configuration, not model behavior. The setup draft
stores it while incomplete, and completion assigns it to the stable monitor while the immutable
version stores the exact provider/model and behavior fingerprint.

Changing or rotating a key therefore does not claim that the prompt/model behavior changed. Future
execution still resolves the credential server-side by ID and must stop safely when it is invalid,
revoked, superseded, missing, or provider-incompatible.

## Server and route design

All routes live under `/app/:workspace_slug` with the existing `:browser`, `:authenticated`, and
`:workspace_scope` pipelines. Controllers remain an integration boundary; validation, tenancy,
promotion, and progress derivation stay in contexts.

- `GET /monitors/new` and `POST /monitors` start the flow.
- `GET /monitors/:id/setup` resumes at the next incomplete step.
- `GET/PATCH /monitors/:id/setup/:step` render and persist each supported step.
- `POST /monitors/:id/setup/complete` promotes the complete draft.
- `POST /monitors/:id/setup/leave` records an explicit save-and-exit event without customer content.

## UI approach

- Replace the foundation dashboard with monitor-aware empty and resumable states.
- Enable monitor navigation and add a workspace switcher sourced from verified memberships.
- Keep alerts visible but unavailable until its owning task rather than creating a misleading page.
- Use Inertia `useForm` with Phoenix changeset errors as the validation source of truth.
- Use a single responsive setup page with explicit step URLs, accessible controls, bounded dynamic
  cases, loading labels, and recovery guidance.
- Do not use the manually toggled onboarding checklist pattern in `high_school`; derive every check
  from stored monitor/setup/version state.

## Product-learning events

Task 6 adds a small append-only, workspace-scoped allowlist for setup-started, step-completed,
save-and-exit, and setup-completed events. Properties contain only step names and counts—never prompt,
context, input variables, imported JSON, credential metadata, or output content.

## Risks and mitigations

- **Draft and version validation drift:** promotion always passes through Task 5's authoritative
  `VersionInput` normalizer.
- **Cross-workspace credential selection:** query the credential through the current workspace and
  verify provider/status again inside the completion transaction.
- **Half-completed promotion:** lock the setup/monitor and update draft status, monitor credential,
  and immutable version inside one database transaction.
- **Oversized browser payloads:** enforce existing server limits regardless of input attributes and
  surface the limits before submission.
- **Telemetry leakage:** accept only internal event names and allowlisted count/step properties.
- **False progress:** recompute progress from valid persisted values on every request.

## References

- [Inertia forms and server-side validation](https://inertiajs.com/docs/v3/the-basics/forms)
- [Ecto embedded schemas and intermediate state](https://ecto.hexdocs.pm/embedded-schemas.html)
- [Phoenix controller testing](https://phoenix.hexdocs.pm/testing_controllers.html)
- [`high_school` reference repository](../../../high_school)
