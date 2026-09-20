# Hosted Pilot Operations

## Boundary

This is the production operations contract for the controlled design-partner pilot. It does not
authorize Fly.io resources, secrets, a deployment, the invitation switch, or a customer invitation.
Those are distinct external actions.

## Health surfaces

| Surface | Authentication | Healthy response | Purpose |
| --- | --- | --- | --- |
| `GET /health/live` | None | HTTP 200 | Process liveness only |
| `GET /health/ready` | None | HTTP 200 after `SELECT 1` | Traffic routing and deploy health |
| `GET /health/operations` | Bearer `OPERATIONAL_HEALTH_TOKEN` | HTTP 200 for `ok` or `degraded`; 503 for `critical` | Content-free operational alert source |
| `mix silent_regression.ops_check` | Release shell | Exit 0 only for `ok` by default | Operator and external scheduled check |

Do not route on `/health/operations`. Removing healthy web Machines during a backlog can make
recovery worse. Configure Fly service health against `/health/ready`; health checks do not follow
redirects, so include `X-Forwarded-Proto: https` if the endpoint would otherwise redirect behind
TLS termination.

## Operational thresholds

| Check | Degraded | Critical | First response |
| --- | --- | --- | --- |
| Queues | More than 100 available jobs or any queue's oldest job exceeds 5 minutes | Any discarded monitored-queue job in 24 hours | Inspect safe job IDs and queue/worker state |
| Scheduler | — | Missing/error heartbeat older than 3 minutes or an eligible monitor over 15 minutes late | Stop new spend if dispatch identity is uncertain; inspect dispatcher leadership/jobs |
| Provider outcomes | — | Any unknown observation/attempt or expired started attempt | Do not replay; reconcile request provenance first |
| Notifications | Failed delivery or pending delivery older than 15 minutes | — | Inspect recipient/status metadata only; use idempotent retry path |
| Purge | A due closed workspace is more than 30 minutes overdue | Explicit request exceeds 7 days or purge worker reports error | Contain, verify exact target and receipt, escalate as deletion incident |

The purge worker runs every 15 minutes and processes at most 25 workspaces per pass. The scheduler
dispatcher runs every minute. Both update content-free heartbeats.

## Deployment and rollback sequence

1. Obtain explicit deployment authorization. Record source SHA, image digest, migration version,
   backup timestamp, release owner, and rollback owner.
2. Set all required production secrets from
   [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md), including
   `PILOT_INVITATIONS_ENABLED=false`.
3. Deploy, run release migrations, and require `/health/live` and `/health/ready` to pass. Confirm
   the external bearer-protected operations check is receiving snapshots without logging its token.
4. Run `mix silent_regression.ops_check` and the deterministic browser/fake-provider smoke.
5. Exercise backup restore, deletion reconciliation, rollback/forward migration, key rotation, and
   incident-response tabletop in the target environment. Record only passed drills with exact
   evidence references; record failures as failed.
6. Run `mix silent_regression.pilot_readiness`. It remains blocked while the invitation switch is
   false; every other line must be current and operational health must be `ok`.
7. Obtain separate authorization to enable invitations, deploy only that configuration change, and
   rerun readiness.
8. Obtain separate authorization for the first invitation. Monitor health and spend during the
   assisted onboarding window.

Rollback immediately for failed migrations, health/readiness failures, secret/keyring errors,
cross-tenant behavior, unbounded provider calls, or unreconcilable deletion evidence. Keep the
restored/rolled-back system isolated until the signed deletion ledger preview and execution report
no reintroduced actionable workspace.

## Drill records

Accepted kinds are `backup_restore`, `rollback`, `key_rotation`, `deletion_reconciliation`, and
`incident_response`. Records expire after 90 days. Backup restore, rollback, and deletion
reconciliation are also bound to the exact `PILOT_RELEASE_SHA`; a new release invalidates them.

```shell
mix silent_regression.record_drill \
  --kind rollback \
  --outcome passed \
  --operator pedro \
  --evidence-ref ops://production/YYYY-MM-DD/rollback-1

mix silent_regression.pilot_readiness
```

Evidence references must point to the private, content-free operator record. Never put customer
content, credentials, outputs, invitation tokens, or review rationale in a drill row.

## Ownership

Pedro is incident commander, deploy/rollback owner, and partner communicator for the controlled
pilot. External escalation follows the affected boundary: Fly.io/managed Postgres, Resend, OpenAI,
Anthropic, and the design partner's verified workspace owner. If Pedro is unavailable, keep
invitations and monitoring disabled.

## Platform references

- [Fly.io health checks](https://fly.io/docs/reference/health-checks/)
- [Fly.io application configuration](https://fly.io/docs/reference/configuration/)
- [Fly.io Postgres backup and restore](https://fly.io/docs/postgres/managing/backup-and-restore/)
- [Oban periodic jobs](https://oban.hexdocs.pm/periodic_jobs.html)
