# Private-Alpha Operator Runbook

## Scope

This runbook covers the closed, founder-assisted alpha. It assumes one operator with shell and
database access, invite-only accounts, customer-supplied provider credentials, and no billing.
Never paste prompts, contexts, outputs, credentials, bearer tokens, or review rationale into tickets,
chat, logs, or operator notes.

## Invite a design partner

1. Confirm the workspace name, slug, owner email, timezone, and intended provider out of band.
2. Preview the exact command and then run:

   ```shell
   mix silent_regression.invite \
     --workspace-name "Acme AI" \
     --workspace-slug acme-ai \
     --email owner@acme.example \
     --role owner
   ```

3. Send the one-time URL through the agreed private channel. It is not stored in plaintext.
4. If it is exposed, revoke it in the product/operator path and issue a new invitation.

## Founder assistance

Record only an allowlisted stage and reason after a support session:

```shell
mix silent_regression.record_assistance \
  --workspace-slug acme-ai \
  --monitor-id MONITOR_UUID \
  --actor-email owner@acme.example \
  --stage contract \
  --reason onboarding
```

Do not record free-form notes. Product events and audit records intentionally reject arbitrary keys.

For help understanding the credential-free demo, omit the monitor ID and use the `demo` stage:

```shell
mix silent_regression.record_assistance \
  --workspace-slug acme-ai \
  --actor-email owner@acme.example \
  --stage demo \
  --reason onboarding
```

Review content-free demo completion, time to a proven case expectation, time to completion, and
founder-assistance counts without printing customer inputs or event-level user identities:

```shell
mix silent_regression.pilot_metrics \
  --workspace-slug acme-ai \
  --actor-email owner@acme.example
```

## Failed background jobs

1. Inspect Oban queue health and the failure category, attempt count, worker, and record IDs only.
2. Do not copy serialized customer content into diagnostics; production jobs accept IDs only.
3. For capture jobs, inspect the durable provider-attempt ledger before retrying. An unknown provider
   outcome must not be silently replayed.
4. Authentication failures require the customer to replace/validate the credential. Repeated failures
   auto-pause the monitor.
5. For alert-email jobs, preference and alert state are rechecked at send time. Retrying the same
   delivery is idempotent.

## Provider incident

1. Identify the affected provider, model, time window, request IDs, and failure categories without
   collecting request or response content.
2. Pause affected schedules if the automated policy has not already done so.
3. Do not switch provider/model in place. The alpha comparison contract is same-provider,
   same-requested-model against its own compatible baseline.
4. Tell affected partners that monitoring is paused and whether any run outcome is unknown.
5. Resume only after credential/model validation and normal capacity checks succeed.

## Contract correction and replacement baseline

An approved contract revision that changes deterministic semantics intentionally invalidates the
current baseline. Historical rescoring makes no provider call, but the monitor cannot compare new
runs against evidence interpreted under the old contract.

1. Confirm the Baseline page identifies the exact compatibility change and still shows the sealed
   historical evidence.
2. Review the replacement preview and its maximum calls and output-token ceiling. Authorizing it is
   a new provider-spend decision; it does not approve the resulting outputs.
3. Inspect every replacement output and deterministic judgment. The old baseline remains approved
   and auditable while this capture is pending, and a rejected replacement returns the page to the
   same replacement preview.
4. Approve the replacement only when its operational evidence is complete. Approval atomically
   marks the old reference superseded and makes the new one current.
5. Return to Monitor Operations and explicitly configure the desired manual, daily, or weekly
   cadence. Replacement authorization clears the next scheduled time rather than silently
   restarting the previous schedule.

## Provider smoke verification

Preview each provider independently with the exact existing credential ID, workspace, and allowed
model. Previewing decrypts no credential and makes no provider request:

```shell
mix silent_regression.provider_smoke \
  --workspace-slug acme-ai \
  --provider anthropic \
  --model claude-haiku-4-5-20251001 \
  --credential-id CREDENTIAL_UUID
```

The fixed smoke contract has one case, one sample, zero retries, 16 maximum output tokens, and one
maximum provider call. Obtain fresh, provider-specific user authorization only after reviewing the
printed fingerprint and envelope. Then add `--execute` plus the exact printed provider, model,
maximum-call count, and fingerprint confirmations. Never reuse one provider's authorization for
the other provider. Execution writes a `started` receipt under `results/provider_smoke` before the
network request and updates it with the safe result afterward. If terminal output is interrupted,
inspect that receipt before considering another call; a `started` receipt with no terminal result
means the outcome is unknown and must not be replayed without fresh authorization. The receipt and
task output include safe provenance and contract status but never the credential secret, prompts,
context, or captured output.

## Workspace closure, recovery, and deletion

Customer owners initiate closure/deletion in **Data & retention** after typing the exact workspace
slug. Follow [DATA_RETENTION.md](DATA_RETENTION.md) for policy and commands.

- A normal closure can be recovered for 30 days with the verified owner email.
- An explicit deletion cannot be reopened and is due for purge immediately.
- Run the purge command without `--execute` first. Match slug, request type, and due timestamp.
- Store the content-free request ID in the support record; do not add workspace content.
- Complete explicit deletion within seven days.

## Usage-cap support

The approved defaults are 20 authorized runs/day/workspace, 200 reserved provider calls/day/workspace,
and 200 calls/run. The UTC reset time is shown in Monitor Operations. Do not change pilot policy in
the database as an ad-hoc support fix. A policy change needs a reviewed code/config decision.

## Escalation

Use [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) for suspected disclosure, cross-tenant access,
credential compromise, deletion failure, or unexplained provider spending. Stop execution first;
preserve content-free evidence; communicate known facts and uncertainty separately.
