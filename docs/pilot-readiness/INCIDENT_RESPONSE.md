# Private-Alpha Incident Response

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
