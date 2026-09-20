# Deployment-Readiness Checklist

This checklist prepares a later Fly.io deployment; it does not authorize creating Fly resources.

## Application and infrastructure

- [ ] Production Postgres is encrypted, access-restricted, monitored, and backed up with <=30-day
      expiry.
- [ ] `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST` are set from the secret store.
- [ ] `OPERATIONAL_HEALTH_TOKEN` contains at least 32 random bytes and is available only to the
      external operations checker.
- [ ] `PILOT_RELEASE_SHA` exactly identifies the deployed release and `PILOT_ENVIRONMENT` names the
      target environment.
- [ ] `PILOT_INVITATIONS_ENABLED=false` remains set through deployment and all target drills.
- [ ] TLS termination, HSTS, `GET /health/live`, `GET /health/ready`, release migrations, rollback,
      and DNS are verified. The readiness probe supplies `X-Forwarded-Proto: https` if the platform
      checks the application directly behind TLS termination.
- [ ] Oban `capture`, `scheduler`, `notifications`, `contract_rescore`, and `maintenance` queues have
      adequate concurrency and alerts.
- [ ] A single scheduler dispatch contract is verified across all running machines.
- [ ] An external one-minute check calls bearer-protected `GET /health/operations` and pages on
      degraded or critical state; its token never enters URLs or logs.

## Secrets and email

- [ ] `PROVIDER_CREDENTIAL_ENCRYPTION_KEY_V1` is a unique Base64 32-byte key.
- [ ] Optional V2 rollout follows [KEY_ROTATION.md](KEY_ROTATION.md).
- [ ] Independent Base64 32-byte `RATE_LIMIT_HMAC_KEY` and `DELETION_RECEIPT_HMAC_KEY` are set.
- [ ] `RESEND_API_KEY`, verified `MAIL_FROM`, and `MAIL_FROM_NAME` are set.
- [ ] Resend domain authentication, bounce handling, and a content-free delivery smoke are verified.
- [ ] Secret values are absent from image layers, release output, logs, crash reports, and support
      systems.
- [ ] Pedro's GitHub, Fly.io, database, Resend, OpenAI, and Anthropic operator accounts use
      provider MFA. Application MFA is explicitly not claimed for this controlled pilot.

## Product and operations

- [x] Invite, activation, baseline, schedule, result, alert, review, correction, and closure flows pass
      with fake providers from the browser.
- [x] Separate bounded OpenAI and Anthropic smoke calls receive just-in-time authorization.
- [x] Limits, model allowlists, rate limits, notification preferences, and deduplication pass.
- [x] Cross-tenant, sensitive-data, purge, and local restore/reconciliation tests pass.
- [ ] Target-environment backup/restore, rollback, deletion-reconciliation, key-rotation, and
      incident-response drills pass and are current.
- [x] Operator and incident runbooks name Pedro as primary owner and define escalation paths.
- [ ] The design partner's verified contact and private communication channel pass a content-free
      test.
- [ ] Customer-visible alpha data notice and known limitations are acknowledged by each partner.
- [x] Public registration, self-serve billing, and Stripe remain absent.

## Go/no-go record

Record commit SHA, migration version, image digest, database backup timestamp, verification output,
approved provider-call budget, operator, rollback owner, and outstanding risks. Any failed unchecked
security, deletion, tenancy, or secret-management item is a no-go.

After the deployment is separately authorized, follow [HOSTED_OPERATIONS.md](HOSTED_OPERATIONS.md).
Do not enable invitations in the initial deployment. When every checklist item and
`mix silent_regression.pilot_readiness` passes in the target environment, request separate
authorization to deploy `PILOT_INVITATIONS_ENABLED=true`; then request separate authorization for
the first invitation.
