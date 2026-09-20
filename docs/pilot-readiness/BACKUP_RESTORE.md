# Backup and Restore Drill

## Policy

Disaster-recovery backups must be encrypted and expire within 30 days. They are not an alternate
customer-content archive. Access is limited to documented disaster recovery.

The signed deletion ledger is the authoritative post-backup deletion signal. Export it after each
deletion completion and on the backup cadence, then store it in a protected location separate from
the database backup:

```shell
mix silent_regression.deletion_ledger --output /secure/separate-store/deletions.json
```

## Pre-deployment drill

1. Record the release SHA, backup timestamp, backup age, ledger timestamp/digest, operator, and
   rollback owner. Create a temporary Postgres database with no route to production traffic.
2. Restore the latest encrypted backup into it. Do not point workers, email, or provider traffic at
   the restored database.
3. Run all migrations and application startup checks with the same versioned Cloak keyring.
4. Verify row counts and referential integrity for workspaces, memberships, credentials, monitors,
   captures, baselines, alerts, reviews, notification deliveries, and deletion receipts.
5. Verify a sample encrypted credential can be decrypted without printing it.
6. Preview the separately stored signed ledger against the isolated restore:

   ```shell
   mix silent_regression.reconcile_deletions --ledger /secure/separate-store/deletions.json
   ```

7. Review the signature, exact printed SHA256, entry counts, and `Would reapply` count. If nonzero,
   execute using that exact digest while the database remains isolated:

   ```shell
   mix silent_regression.reconcile_deletions \
     --ledger /secure/separate-store/deletions.json \
     --execute \
     --confirm-ledger-sha EXACT_SHA256
   ```

8. Repeat the preview. It must report no reintroduced actionable workspace. Verify completed/due
   workspaces and sole-workspace accounts are absent before the restored database can be promoted.
9. Run `mix silent_regression.ops_check`, the fake-provider end-to-end smoke, and a content-free
   alert-email test.
10. Exercise the release rollback and forward migration on the isolated copy. Destroy the temporary
    restore and record duration, checks, and outcome.
11. Only after every check passes, record the target-environment `backup_restore`, `rollback`, and
    `deletion_reconciliation` drills with the current release SHA.

## Failure conditions

Do not promote a restore if migrations fail, a configured key cannot decrypt its ciphertext,
deletion receipts cannot be reconciled, tenant isolation checks fail, or the fake-provider journey
does not complete. A missing, invalid, or stale ledger is a restore failure, not permission to serve
the backup.
