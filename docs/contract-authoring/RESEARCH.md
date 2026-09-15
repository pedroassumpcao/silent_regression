# Contract Authoring and Approval Research

## Scope

Task 8 turns the pure deterministic engine from Task 7 into a workspace-scoped authoring and
approval workflow. It persists contract versions and customer fixtures, evaluates fixtures locally,
and seals an exact contract-plus-fixture snapshot after explicit owner approval.

It does not execute provider calls, capture baseline observations, persist production evaluations,
or create alerts. Those boundaries remain in Tasks 9, 10, and 12.

## Product objective

The alpha must answer a narrow product question: can a design partner state deterministic output
requirements, prove those requirements against examples they understand, and approve the result
without reading or editing the internal contract JSON?

The authoring flow therefore optimizes for inspectability rather than maximum language power:

1. Select a workflow-shaped starter template.
2. Configure explicit rules in structured form controls.
3. Add at least one output that should pass and one output that should fail.
4. Review expected versus actual overall and per-rule judgments.
5. Correct rules, outputs, or expected judgments until every fixture agrees.
6. Have a workspace owner explicitly approve and seal the version.

## Approaches considered

### Raw contract JSON as the primary editor

This exposes every Task 7 primitive with little UI work, but it asks design partners to understand
an internal DSL, stable IDs, composition, and evidence semantics before the product has proved that
they can express their requirements. It also makes ordinary syntax mistakes feel like model-quality
problems.

### A fully general visual expression tree

A recursive editor for arbitrary `all`, `any`, and `not` nesting would expose the whole language,
but it creates substantial interaction and validation complexity for the first alpha. Most initial
requirements can be expressed as a conjunction of explicit leaf rules.

### Workflow templates with a bounded flat rule editor (selected)

The initial product starts with four templates: structured JSON, classification/routing, grounded
answers, and required/prohibited text. Each produces an `all` root with editable leaf rules. Users
may add any supported leaf primitive, but arbitrary nested composition remains available only in
the engine, not in the alpha form.

The product shows a validated, read-only JSON representation for transparency and support. It does
not accept raw JSON edits in Task 8.

## Persistence model

### Contract versions

A contract version belongs to one workspace, monitor, and exact monitor configuration version. It
stores:

- a monotonic version number and optional predecessor;
- lifecycle state (`draft`, `approved`, or `retired`);
- schema and evaluator engine versions;
- the selected template and the accepted/edited/removed status of every suggested rule;
- whether authoring was self-serve, founder-assisted, or Codex-assisted;
- the validated deterministic rule tree;
- the engine contract fingerprint;
- a fixture-set fingerprint and a combined approval fingerprint; and
- creator, approver, and lifecycle timestamps.

Draft content may be edited. Approved and retired content is database-protected from mutation. A
request to edit an approved version creates a successor draft with copied rules and fixtures.

### Contract fixtures

A fixture belongs to one contract version and stores a human name, immutable-on-approval output
text, expected overall outcome, expected status for every rule, its position, creator, and a content
fingerprint. Actual outcomes are produced by the Task 7 evaluator on demand rather than copied into
a second source of truth.

Changing draft rules keeps fixture outputs but clears their expected rule judgments. This forces a
fresh review instead of silently carrying expectations across a different contract.

## Approval invariant

Approval is a locked transaction and is allowed only when:

- the actor is a workspace owner;
- the version is the monitor's current draft;
- the contract still parses under its recorded schema version;
- at least one fixture is expected to pass and at least one is expected to fail;
- every fixture has a complete expected status for every rule;
- every local actual overall and per-rule result equals the expected judgment;
- no fixture produces an evaluator error; and
- all contract, fixture-set, and combined fingerprints are recomputed from the locked rows.

Any earlier approved version is retired only as the new version is approved. The approval audit
event contains identities, versions, counts, and fingerprints, never fixture output.

## Template provenance

Each template owns stable suggestion keys and default rule maps. Saving a draft compares its rules
with that frozen template definition:

- `accepted`: the suggested rule is retained unchanged;
- `edited`: its stable rule ID remains but its configured content changed;
- `removed`: its stable rule ID is absent; and
- `added`: a rule not present in the starter was added by the author.

This record is product-learning evidence, not a claim that the template was correct. The separate
assistance mode records whether the customer completed the draft alone or with founder/Codex help.

## Authorization and routing

All routes remain under `/app/:workspace_slug` and use the existing browser, authenticated-user,
and verified-workspace pipelines. The current scope is passed as the first argument to every
contract-authoring context operation. Owners and members may create drafts, edit rules, and validate
fixtures. Only owners may approve a version.

Malformed IDs and cross-workspace records return the same not-found response. React receives only
records already authorized by the server.

## UI behavior

- Template cards explain what each workflow can and cannot check.
- Rule forms use the installed shadcn inputs, selects, textareas, cards, badges, alerts, and dialog.
- Stable rule IDs are visible and editable but explained as durable evidence labels.
- Lists such as labels, phrases, and source IDs use one value per line.
- JSON expected values use a small validated JSON field; arbitrary executable code and regular
  expressions are never accepted.
- Fixture cards show expected and actual badges for the overall result and every rule.
- Approval blockers are listed directly beside the owner-only approval action.
- Members see the same evidence with a clear owner-approval requirement.
- The advanced dialog shows the exact validated contract JSON and fingerprints read-only.

Inertia's form helper remains responsible for submission state while Phoenix changesets and domain
validation remain authoritative. Inertia documents that server-side validation errors are returned
through page props while preserving form state, which matches the established Task 6 flow.

## Limits and safety

- At most 20 fixtures per contract version.
- Fixture output uses the Task 7 one-megabyte evaluator limit.
- Contract rule count, nesting, string, source, numeric, and pointer limits remain owned by the Task
  7 parser.
- Contract and fixture output parameters remain filtered from request logs.
- Fixture evaluation is local and deterministic; Task 8 contains no provider adapter call.
- User input is never converted to atoms and never compiled as code or regular expressions.

## Testing strategy

- Context tests cover tenancy, template provenance, fingerprint changes, fixture agreement,
  owner-only approval, revision, and database immutability.
- Controller tests cover authenticated workspace routing, validation errors, member/owner behavior,
  and safe Inertia props.
- Frontend tests cover template selection, rule configuration, expected/actual evidence, approval
  blockers, read-only JSON, and member approval restrictions.
- A browser pass covers draft creation, a contradictory fixture, correction, owner approval, and
  successor-draft creation without provider traffic.

## References

- [Ecto.Multi](https://hexdocs.pm/ecto/Ecto.Multi.html)
- [Ecto migrations and partial indexes](https://ecto-sql.hexdocs.pm/Ecto.Migration.html)
- [Inertia v2 forms](https://inertiajs.com/docs/v2/the-basics/forms)
- [Inertia v2 validation](https://inertiajs.com/docs/v2/the-basics/validation)
- [shadcn/ui Select](https://ui.shadcn.com/docs/components/radix/select)
- [shadcn/ui Dialog](https://ui.shadcn.com/docs/components/radix/dialog)
- [Task 7 deterministic contract boundary](../contracts/RESEARCH.md)
