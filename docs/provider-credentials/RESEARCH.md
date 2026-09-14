# Provider Credential Security Research

## Overview

Task 4 lets a workspace store and validate OpenAI or Anthropic credentials so Silent Regression
can perform managed replay later. The immediate design goal is a narrow private-alpha control plane,
not a general secrets platform.

The encryption decision must be evaluated together with tenant authorization, secret lifecycle,
provider-call redaction, key rotation, and the future worker boundary. Encrypting the database value
alone is necessary but insufficient.

## Problem Statement

Customer provider credentials must survive application restarts and be available to scheduled jobs,
while remaining absent from plaintext database rows, backups, logs, exceptions, Inertia props,
analytics, URLs, audit metadata, and job arguments.

The primary alpha threat being addressed is disclosure through a database dump, backup, read-only
database access, or accidental broad query. Because a worker must eventually decrypt a credential to
call a provider, application-level encryption does not protect against a compromised application
process, malicious deploy, or an operator who can execute arbitrary production code.

## User Stories / Use Cases

- A workspace owner stores an OpenAI or Anthropic credential and sees only safe metadata afterward.
- The application validates the credential without exposing it in the response or logs.
- A member can use an authorized credential for a monitor without retrieving its plaintext value.
- An owner rotates a provider credential by creating a new immutable credential record that
  supersedes the old record; historical runs retain their original credential identity.
- An owner revokes a credential and no later execution can resolve its secret.
- An operator rotates the application's encryption key without downtime or losing existing values.

## Technical Research

### Required security boundaries

1. Every credential query is workspace-scoped.
2. Only a private execution/validation function may load the decrypted field.
3. Public list and detail functions select safe metadata and never load the encrypted field.
4. The schema marks the field redacted; application inspection and errors must not reveal plaintext.
5. Provider adapters accept plaintext only at the final request boundary and return normalized,
   secret-free results.
6. Workers receive a credential ID and workspace identity, then resolve the active secret at execution
   time after rechecking scope and state.
7. Provider-key rotation and application-master-key rotation are separate lifecycle operations.

### Approach options

| Option | Advantages | Disadvantages | Alpha fit |
| --- | --- | --- | --- |
| `Cloak.Ecto` with AES-256-GCM and one application keyring | Small Phoenix/Ecto integration; authenticated encryption; random IVs; tagged ciphertext; transparent local Ecto type; documented zero-downtime key rotation and migration task | The application key and decrypted values exist in application memory; transparent decryption makes overly broad schema loads dangerous; no per-workspace keys through the Ecto type; adds a dependency whose latest release is `1.3.0` from 2024 | **Best fit** |
| Custom application encryption using Erlang `:crypto` | No third-party dependency; complete control over the ciphertext envelope, associated data, and context-level decryption; possible workspace binding | We own nonce handling, authentication tags, format versioning, migration tooling, rotation, failure behavior, and security review; substantially higher chance of a subtle cryptographic defect | Poor fit unless Cloak cannot satisfy a concrete requirement |
| External KMS or Vault Transit with envelope encryption | Root key remains in a managed key system; centralized permissions and auditability; strong rotation/rewrap story; can support per-workspace data keys and crypto-shredding | Adds another production dependency, identity system, network failure mode, latency, cost, and operational runbook; cross-cloud access from Fly.io is more complex; the application still receives plaintext or a plaintext data key during use | Strong later option for enterprise requirements |
| PostgreSQL `pgcrypto` | Database-native and avoids an Elixir encryption dependency | Keys and plaintext cross the database connection; authorization and rotation become SQL concerns; database/query logging risk increases; PostgreSQL explicitly advises client-side crypto when the database or administrators are not trusted; raw cipher functions lack integrity protection | Reject |
| Store every customer credential as an individual Fly secret | Keeps provider credentials out of PostgreSQL and uses Fly's encrypted vault | Fly secrets are app-level environment variables, not dynamic tenant records; changes update/restart Machines; names and lifecycle do not map cleanly to self-service workspace credentials; deploy-capable operators and application code can still read them | Suitable for the one application master key, not customer credentials |

### Recommended approach

Use `cloak_ecto ~> 1.3` with a local `SilentRegression.Encrypted.Binary` type backed by a supervised
`SilentRegression.Vault`. Configure `Cloak.Ciphers.AES.GCM` with a 32-byte key and a 12-byte IV.
Keep the Ecto field behind the local type so product schemas do not directly depend on a remote module
name and ciphertext can be migrated later if the threat model changes.

Use a single application keyring for the private alpha. Supply production keys as Base64-encoded
runtime environment variables through Fly secrets; never compile or commit a production key. Tests
use a fixed test-only key. Development may use an explicit development-only key, but any live
credential smoke test must use an environment-provided key and remove its temporary record afterward.

Master-key rotation should be versioned and zero-downtime:

1. Generate `V2` independently and keep `V1` available.
2. Configure `V2` first in Cloak's cipher list and retain `V1` as retired.
3. Deploy so new writes use `V2` while old ciphertext remains readable.
4. Run the Cloak Ecto migration for the credential schema in a controlled release operation.
5. Verify all ciphertext is readable under `V2`, back up the recovery material separately, and only
   then remove `V1` in a later deploy.

Provider credential rotation should create a new credential row with a `supersedes_id` relationship,
mark the old row `superseded`, and retain both safe identities for historical provenance. Revocation is
terminal for new execution. This is distinct from re-encrypting unchanged credentials under a new
application master key.

### Required technologies

- `cloak_ecto ~> 1.3` and its `cloak ~> 1.1` dependency
- Erlang/OTP `:crypto` through Cloak's AES-GCM cipher
- Existing Ecto/PostgreSQL persistence and workspace scope
- Existing `Req` HTTP client behind a new product provider behaviour
- Fly secrets later for the application encryption keyring

The current package metadata shows `cloak_ecto 1.3.0` supports Ecto `~> 3.0`; the core `cloak`
repository remains active and tests against current Elixir/OTP releases. The Ecto adapter has a small,
stable surface but a slower release cadence, so dependency behavior must be pinned and covered by our
own encryption and rotation tests.

## Data Requirements

Recommended `ProviderCredential` fields:

- `workspace_id`
- `provider` (`openai` or `anthropic`)
- user-defined `label`
- encrypted, redacted `secret`
- safe `secret_suffix` and a non-reversible duplicate-detection fingerprint if needed
- lifecycle `status` (`pending_validation`, `valid`, `invalid`, `revoked`, `superseded`)
- `last_validated_at`, normalized `last_validation_status`, and safe failure category
- `supersedes_id`, `created_by_user_id`, `revoked_by_user_id`, and lifecycle timestamps

Do not store provider response bodies for credential validation. Store only provider, requested model
when applicable, returned model, safe request ID, HTTP category, attempt count, and timestamps.

## UI/UX Considerations

- Owners can add, validate, rotate, and revoke credentials.
- Members can see provider, label, suffix, and status and may select valid credentials for monitors,
  but cannot reveal or replace secrets.
- The secret is write-only: after submission it is never rendered back into the browser.
- Rotation asks for a new secret and creates a successor; it never pre-fills the old value.
- Validation errors use actionable categories such as authentication, model permission, rate limit,
  transport, or provider outage without including provider response content that may echo inputs.

## Integration Points

- Reuse the spike adapters' proven error categories, retry accounting, exact-model checks, and request
  provenance as design evidence, but implement a product provider behaviour outside
  `SilentRegression.Spike`.
- Extend `SilentRegression.Audit` with content-free credential lifecycle events.
- Add authenticated routes under `/app/:workspace_slug` using the existing `:workspace_scope`
  pipeline because credential records are tenant-owned.
- Task 5 monitor versions will reference credential IDs. Task 9 workers must load the secret privately
  from that ID at execution time and must never receive plaintext through job arguments.

## Risks and Challenges

- Losing every configured master key makes existing credentials unrecoverable. Keep separate,
  access-controlled recovery material and test restoration before external use.
- A database dump plus the Fly/runtime key defeats at-rest encryption; these must remain in separate
  systems with separate access paths.
- Ecto automatically decrypts a Cloak field when selected. Public queries must select metadata rather
  than whole credential structs.
- Debug inspection, telemetry, HTTP middleware, exception capture, and provider error bodies are more
  likely leak paths than the encrypted column itself. Tests must use sentinel secrets and search
  rendered props, captured logs, errors, audit records, and raw database rows.
- External KMS becomes justified if design partners require per-tenant keys, customer-managed keys,
  cryptographic deletion, hardware-backed roots, or isolation from deploy-capable operators.

## Open Questions

1. Approve the recommended Cloak.Ecto application-key approach or select a different option.
2. Confirm the authorization default: owners manage credentials; members may view safe metadata and
   use valid credentials in monitors but cannot create, rotate, or revoke them.

## References

- [Cloak.Ecto overview and security notes](https://cloak-ecto.hexdocs.pm/readme.html)
- [Cloak.Ecto installation and runtime-key configuration](https://cloak-ecto.hexdocs.pm/install.html)
- [Cloak key rotation](https://cloak-ecto.hexdocs.pm/rotate_keys.html)
- [Cloak AES-GCM ciphertext format](https://hexdocs.pm/cloak/Cloak.Ciphers.AES.GCM.html)
- [Fly.io secrets](https://fly.io/docs/apps/secrets/)
- [AWS KMS envelope encryption](https://docs.aws.amazon.com/kms/latest/developerguide/kms-cryptography.html)
- [Vault Transit secrets engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [PostgreSQL pgcrypto security limitations](https://www.postgresql.org/docs/current/pgcrypto.html#PGCRYPTO-NOTES)
