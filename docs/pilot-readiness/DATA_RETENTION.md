# Private-Alpha Data Retention and Deletion

## Customer lifecycle

### Active workspace

Prompt templates, frozen context, input variables, provider outputs, evaluation evidence, baselines,
and review history are retained for the active life of the workspace. They are required to explain
alerts, reproduce comparisons, and preserve the immutable evidence chain.

### Closed workspace

Only a workspace owner can close a workspace, and the owner must type the exact workspace slug.
Closure immediately:

- cancels active capture runs and queued workspace notification jobs;
- pauses active monitors and removes their next scheduled run;
- revokes every active provider credential;
- revokes pending invitations; and
- removes the workspace from normal authenticated tenant lookup.

The application retains a normally closed workspace for 30 days. During that window, an operator
may reopen it for a verified owner. Reopening does not restore credential access or resume monitors;
the owner must deliberately reconfigure those controls.

### Explicit deletion request

Only a workspace owner can request deletion, with the same exact-slug confirmation. The immediate
shutdown behavior is identical to closure. The workspace becomes eligible for irreversible purge
immediately, and the private-alpha operational commitment is to execute the purge within seven
days. An explicit deletion request cannot be reopened.

### Purged workspace

The purge deletes workspace content, credentials, memberships, invitations, audit records, product
events, monitoring evidence, notification records, and workspace-owned background jobs in a tested
foreign-key-aware order. An account is also removed if it no longer belongs to any other workspace.
Accounts with another membership remain intact.

The only retained application record is a content-free deletion receipt containing a random request
ID, a one-way keyed workspace fingerprint, request type, status, and lifecycle timestamps. It has no
workspace foreign key and contains no workspace name, slug, email, prompt, output, provider secret,
or free-form customer text.

### Disaster-recovery backups

Purged data may remain in encrypted disaster-recovery backups until those backups expire. The
maximum approved backup expiry window is 30 days. Backups are for disaster recovery, not ordinary
customer-data retrieval, and a restore procedure must reapply due deletion receipts before restored
data can serve production traffic.

## Operator commands

Preview a due purge without changing data:

```shell
mix silent_regression.purge_workspace \
  --workspace-slug acme-ai \
  --confirm-slug acme-ai
```

Execute only after reviewing the preview:

```shell
mix silent_regression.purge_workspace \
  --workspace-slug acme-ai \
  --confirm-slug acme-ai \
  --execute
```

Recover a normal closure during its 30-day window:

```shell
mix silent_regression.reopen_workspace \
  --workspace-slug acme-ai \
  --confirm-slug acme-ai \
  --actor-email owner@acme.example \
  --execute
```

These commands intentionally require exact identifiers and never accept a broad selector.
