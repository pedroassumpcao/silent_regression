# Verification

The supported local toolchain is pinned in `.tool-versions`, `.node-version`, and
`assets/package.json`:

- Erlang/OTP 29.0.6
- Elixir 1.20.4
- Node 24.4.1
- npm 11.4.2

After `mix deps.get` and `mix assets.setup`, run the complete tracked repository gate:

```sh
mix precommit
```

That command checks warning-free application compilation, unused lock entries, formatting, backend
tests, TypeScript, frontend tests, and the production asset build.

Run the deterministic browser journey separately:

```sh
assets/node_modules/.bin/playwright-cli install-browser chromium
bin/browser-journey
```

It creates a unique test database, accepts a one-time owner invitation, enters the workspace, and
completes the sealed credential-free demo. It makes zero provider calls and drops only its own test
database during cleanup. Snapshots, screenshots, and traces are written under ignored
`output/playwright/` paths.

Two semantic-spike checks validate private live-run files that are intentionally not committed.
They are not part of CI. An operator who has those artifacts can run them explicitly:

```sh
mix test --include runtime_artifact \
  test/silent_regression/spike/semantic_layer/cheap_benchmark_config_test.exs \
  test/silent_regression/spike/semantic_layer/cheap_benchmark_freeze_test.exs
```

Missing private artifacts must not be interpreted as a product regression. A hash mismatch when
the files are present is an evidence-integrity failure and should be investigated.
