# Private-Alpha Incident Response

## Ownership and contact path

| Responsibility | Pilot owner | Escalation path |
| --- | --- | --- |
| Incident commander, containment, status cadence | Pedro | Hosting/database/provider support as the affected boundary requires |
| Application and release rollback | Pedro | Fly.io and managed-Postgres support |
| Credential/provider-call containment | Pedro | OpenAI or Anthropic organization support plus the affected workspace owner |
| Email delivery | Pedro | Resend support plus the affected recipient |
| Design-partner communication | Pedro | The partner's verified owner contact in the private pilot record |

Do not store phone numbers, bearer links, secrets, or customer content in this repository. Before the
first invitation, Pedro must verify the partner contact and the private communication channel with a
content-free test message. If Pedro is unavailable, monitoring and invitations remain disabled; the
pilot has no unrecorded substitute operator.

## Severity triggers

- **Critical:** suspected cross-tenant access, plaintext credential disclosure, unauthorized provider
  calls, deletion after an approved recovery, or inability to stop execution.
- **High:** material notification misdelivery, repeated unknown provider outcomes, key compromise, or
  missed deletion SLA.
- **Moderate:** isolated failed jobs, provider outage, rate-limit errors, or delayed notification with
  no confidentiality impact.

## First response

1. Record UTC start time, reporter, affected workspace IDs, and safe request/job IDs.
2. Stop the affected execution path: pause monitors, revoke credentials, or close the workspace.
3. Preserve audit, product-event, Oban, and provider-attempt identifiers. Never copy customer content
   or plaintext secrets into the incident record.
4. Determine scope before retrying. Treat an abandoned provider attempt as unknown, not failed.
5. Notify the affected design partner with confirmed facts, current containment, and the next update
   time. Do not speculate.

## Credential or encryption-key compromise

1. Revoke affected customer credentials and pause dependent monitors.
2. Add a new Cloak key as the default while retaining the prior key for decryption.
3. Follow [KEY_ROTATION.md](KEY_ROTATION.md), verify every ciphertext migrated, then wait for backup
   expiry before removing the retired key.
4. Rotate Resend, database, session, and HMAC secrets independently if their scope is implicated.

## Deletion incident

1. Stop purge automation/operation if the target or deadline is ambiguous.
2. Verify the exact slug, keyed receipt fingerprint, request type, and due time.
3. If a restore reintroduced due-deleted data, keep the restored system isolated and reapply deletion
   receipts before serving traffic.
4. Record only the content-free request ID and completion timestamp.

## Closure

Document cause, affected boundaries, containment, customer communication, durable corrective action,
and verification. Add regression tests for the failing boundary before returning the system to normal
operation.

After a target-environment tabletop or incident is closed, record an `incident_response` drill only
when containment, communication, recovery, and the regression boundary were all exercised. A failed
tabletop is recorded as failed and keeps invitation readiness blocked.
