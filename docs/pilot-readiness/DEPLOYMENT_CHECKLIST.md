# Deployment-Readiness Checklist

This checklist prepares a later Fly.io deployment; it does not authorize creating Fly resources.

## Application and infrastructure

- [ ] Production Postgres is encrypted, access-restricted, monitored, and backed up with <=30-day
      expiry.
- [ ] `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST` are set from the secret store.
- [ ] TLS termination, HSTS, health checks, release migrations, rollback, and DNS are verified.
- [ ] Oban `capture`, `scheduler`, and `notifications` queues have adequate concurrency and alerts.
- [ ] A single scheduler dispatch contract is verified across all running machines.

## Secrets and email

- [ ] `PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V1` is a unique Base64 32-byte key.
- [ ] Optional V2 rollout follows [KEY_ROTATION.md](KEY_ROTATION.md).
- [ ] Independent Base64 32-byte `RATE_LIMIT_HMAC_KEY` and `DELETION_RECEIPT_HMAC_KEY` are set.
- [ ] `RESEND_API_KEY`, verified `MAIL_FROM`, and `MAIL_FROM_NAME` are set.
- [ ] Resend domain authentication, bounce handling, and a content-free delivery smoke are verified.
- [ ] Secret values are absent from image layers, release output, logs, crash reports, and support
      systems.

## Product and operations

- [ ] Invite, activation, baseline, schedule, result, alert, review, correction, and closure flows pass
      with fake providers from the browser.
- [ ] Separate bounded OpenAI and Anthropic smoke calls receive just-in-time authorization.
- [ ] Limits, model allowlists, rate limits, notification preferences, and deduplication pass.
- [ ] Cross-tenant, sensitive-data, purge, backup/restore, and key-rotation checks pass.
- [ ] Operator and incident runbooks have named owners and a tested communication channel.
- [ ] Customer-visible alpha data notice and known limitations are acknowledged by each partner.
- [ ] Public registration, self-serve billing, and Stripe remain absent.

## Go/no-go record

Record commit SHA, migration version, image digest, database backup timestamp, verification output,
approved provider-call budget, operator, rollback owner, and outstanding risks. Any failed unchecked
security, deletion, tenancy, or secret-management item is a no-go.
