# Backup and Restore Drill

## Policy

Disaster-recovery backups must be encrypted and expire within 30 days. They are not an alternate
customer-content archive. Access is limited to documented disaster recovery.

## Pre-deployment drill

1. Create a temporary Postgres database isolated from production traffic.
2. Restore the latest encrypted backup into it.
3. Run all migrations and application startup checks with the same versioned Cloak keyring.
4. Verify row counts and referential integrity for workspaces, memberships, credentials, monitors,
   captures, baselines, alerts, reviews, notification deliveries, and deletion receipts.
5. Verify a sample encrypted credential can be decrypted without printing it.
6. Compare completed/pending deletion receipts from the authoritative post-backup record. Reapply all
   purges that were due or completed after the backup timestamp.
7. Verify those workspaces and sole-workspace accounts are absent before the restored database can be
   promoted.
8. Run the fake-provider end-to-end smoke and a content-free alert-email test.
9. Destroy the temporary restore and record date, backup age, restore duration, checks, and operator.

## Failure conditions

Do not promote a restore if migrations fail, a configured key cannot decrypt its ciphertext,
deletion receipts cannot be reconciled, tenant isolation checks fail, or the fake-provider journey
does not complete.
