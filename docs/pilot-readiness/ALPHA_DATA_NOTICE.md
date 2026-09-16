# Private-Alpha Data Notice

Silent Regression is an invite-only design-partner alpha for monitoring deterministic AI workflows.
It is not a general observability proxy and does not install an SDK in your production environment.

## What you provide

You provide a provider API credential, prompt template, frozen test context, input variables,
deterministic evaluation contract, and reviewed test cases. Scheduled runs send the configured test
requests to the provider you selected. OpenAI and Anthropic are the supported alpha providers.

## What is stored

The product stores the supplied configuration, encrypted provider credential, provider outputs,
evaluation evidence, baselines, alerts, reviews, and bounded operational provenance needed to
reproduce and explain a result. Product-learning events contain allowlisted IDs, stages, categories,
counts, and statuses—not prompts, contexts, outputs, credentials, emails, or free-form notes.

## Retention and deletion

Raw monitoring evidence is retained while your workspace is active. Closing a workspace immediately
stops scheduled execution, revokes provider credentials, and starts a 30-day recovery window.
Requesting deletion stops execution immediately and makes the workspace eligible for irreversible
deletion; the alpha commitment is completion within seven days. Encrypted disaster-recovery backups
expire within 30 days. A content-free deletion receipt remains after purge.

## Alpha limitations

- Comparisons are against the workflow's own compatible historical baseline using the same provider
  and requested model.
- Deterministic contracts drive automatic conclusions. Ambiguous semantic judgments remain a human
  review workflow.
- Availability, delivery timing, provider behavior, and model aliases are not guaranteed.
- Usage is capped at 20 authorized runs and 200 reserved provider calls per workspace per UTC day,
  with at most 200 calls in one run.
- Email contains only monitor identity, category, severity, and an authenticated link; detailed
  evidence stays behind workspace authorization.

This is a product/operational notice for the private alpha, not a substitute for counsel-approved
terms, privacy policy, or data-processing agreements before broader release.
