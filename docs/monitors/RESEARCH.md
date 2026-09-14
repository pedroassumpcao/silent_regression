# Versioned Monitor Domain Research

## Overview

Task 5 establishes the durable identity and immutable configuration lineage used by later setup,
execution, baseline, comparison, and review tasks. It does not add the monitor UI, provider execution,
contracts, baselines, or schedules.

The core rule is that a monitor's editable description is not its executable configuration. A
`Monitor` is a stable workspace-scoped identity. Each executable configuration is a complete,
append-only `MonitorVersion` with its own append-only `CaseVersion` snapshot.

## Product boundary

- A design partner may rename a monitor or clarify its human description without invalidating
  compatibility.
- Provider, exact requested model, prompts, response format, generation configuration, case inputs,
  frozen context, and active-case membership are behavior-affecting.
- A behavior-affecting change creates a new complete candidate version. It never updates the current
  version's content.
- Task 6 may persist incomplete onboarding values in a separate setup draft. Only a complete,
  validated snapshot enters version history.
- Activating a candidate version makes it the monitor's current configuration and moves the monitor
  into validation. Any prior current version is preserved as superseded.

## Approaches considered

### Mutable drafts followed by sealing

This uses fewer rows while setup is in progress, but correctness depends on every caller remembering
when mutation is still permitted. It also makes a direct database update capable of silently changing
content unless additional sealing logic is perfectly maintained.

### Event sourcing

An event stream provides complete lineage, but reconstructing current monitor state and validating
partial events adds substantial machinery before the alpha has demonstrated demand for it.

### Complete append-only snapshots (selected)

Each candidate stores all behavior-affecting configuration and its complete case set. This duplicates
small bounded payloads, but makes provenance, inspection, rollback, and later baseline compatibility
straightforward. The alpha limit of 20 active cases keeps that tradeoff modest.

## Selected data model

### `monitors`

- Workspace-scoped stable identity.
- Mutable metadata: name and human description.
- Lifecycle state: `draft`, `validating`, `ready`, `baseline_pending`, `active`, `paused`, or
  `archived`.
- References to the current active configuration and at most one candidate configuration.
- State-change and archival timestamps plus the creating user.

### `monitor_versions`

- Monotonic version number within one monitor and optional predecessor reference.
- Lifecycle status: `draft`, `active`, or `superseded`.
- Exact provider and requested model; no alias resolution or silent substitution.
- System prompt, user prompt template, response-format object, and bounded generation configuration.
- Case-set fingerprint and overall behavior fingerprint.
- Created-by, activation, supersession, and insertion provenance.

### `case_versions`

- Belongs to exactly one monitor-version snapshot.
- Stable customer-defined case key within the snapshot.
- Human name and display position.
- Active or disabled state.
- Frozen input variables and context.
- Fingerprint covering the stable key, active state, variables, and context while excluding display
  name and position.

## Immutability enforcement

The public context exposes no content-update operation. PostgreSQL triggers provide a second line of
defense:

- behavior-affecting `monitor_versions` columns cannot change after insertion;
- `case_versions` rows cannot be updated at all; and
- lifecycle-only monitor-version fields may transition through controlled context functions.

Creating a candidate, inserting all cases, computing its fingerprints, superseding an older
candidate, and updating the monitor reference happen in one database transaction.

## Fingerprints and compatibility

Fingerprints use SHA-256 over a recursively canonicalized, JSON-compatible representation. Map keys
are normalized and sorted; list order is preserved. No additional serialization dependency is
required.

- A case fingerprint excludes display-only name and position.
- A case-set fingerprint sorts cases by stable case key, so display reordering is metadata-only.
- A monitor-version fingerprint covers its schema version, exact provider/model, prompts, response
  format, generation configuration, and case-set fingerprint.
- Compatibility requires equal monitor-version fingerprints, exact provider/model provenance, and
  the same case-key-to-fingerprint mapping. A mismatch returns explicit fields rather than a boolean
  that a later caller might ignore.

## Bounds and normalized input

Limits are application configuration so tests and future pilot adjustments remain explicit:

- 1–20 active cases and at most 50 total cases per version;
- 40,000 bytes per prompt field;
- 100,000 bytes of frozen context per case;
- 50,000 encoded bytes of input variables per case;
- 40,000 encoded bytes for response format;
- 4,000 encoded bytes for generation configuration; and
- 2,000,000 bytes per JSON case import.

Generation configuration initially accepts only `max_output_tokens`, `temperature`, `top_p`, and
`reasoning_effort`, with bounded values. Unknown keys fail validation rather than being ignored.

Manual entry and JSON import both pass through the same normalizer. The import format is versioned
and documented by `case-import-v1.schema.json`; unknown top-level or case fields are rejected.

## Initial model allowlist

The private alpha keeps the already approved spike pairs:

| Provider | Cost-conscious | Higher capability |
| --- | --- | --- |
| OpenAI | `gpt-5.6-luna` | `gpt-5.6-sol` |
| Anthropic | `claude-haiku-4-5-20251001` | `claude-sonnet-5` |

The allowlist is configuration, not provider discovery. Adding or retiring an allowed model is an
explicit product change. Existing versions retain their exact requested ID even if new versions can
no longer select it.

Anthropic documents that current-generation canonical dateless IDs are pinned releases, while older
short aliases can move between dated snapshots. Silent Regression therefore allowlists the canonical
ID when one exists and never rewrites what the user selected.

## Risks and mitigations

- **Snapshot duplication:** bounded case counts and payload limits keep storage predictable.
- **Race between candidate writers:** lock the monitor row and allocate version numbers inside the
  transaction.
- **Bypassing application immutability:** database triggers reject direct content updates.
- **False compatibility from unstable serialization:** canonicalize recursively and protect known
  fingerprints with tests.
- **Provider catalog churn:** keep allowlists configurable and exact; never mutate historical rows.
- **Partial onboarding data in version history:** Task 6 will use a separate persisted setup draft.

## References

- [Ecto changesets and constraints](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Ecto transactions](https://hexdocs.pm/ecto/Ecto.Repo.html)
- [Ecto reversible migration SQL](https://hexdocs.pm/ecto_sql/Ecto.Migration.html)
- [OpenAI model catalog](https://platform.openai.com/docs/models)
- [Anthropic model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model)
- [Anthropic model IDs and versioning](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions)
