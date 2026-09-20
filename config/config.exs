# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :silent_regression, :scopes,
  user: [
    default: false,
    module: SilentRegression.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: SilentRegression.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ],
  workspace: [
    default: true,
    module: SilentRegression.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:workspace, :id],
    route_prefix: "/app/:workspace_slug",
    route_access_path: [:workspace, :slug],
    schema_key: :workspace_id,
    schema_type: :binary_id,
    schema_table: :workspaces,
    test_data_fixture: SilentRegression.WorkspacesFixtures,
    test_setup_helper: :register_and_log_in_workspace
  ]

config :silent_regression,
  ecto_repos: [SilentRegression.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  cloak_repo: SilentRegression.Repo,
  cloak_schemas: [SilentRegression.ProviderCredentials.ProviderCredential]

config :silent_regression, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  cron: [
    crontab: [
      {"* * * * *", SilentRegression.MonitorOperations.Workers.DispatcherWorker, max_attempts: 1}
    ]
  ],
  queues: [capture: 4, scheduler: 1, notifications: 2],
  repo: SilentRegression.Repo

config :silent_regression, :provider_adapters,
  openai: SilentRegression.Providers.OpenAI,
  anthropic: SilentRegression.Providers.Anthropic

config :silent_regression, :monitor_domain,
  schema_version: 1,
  allowed_models: %{
    openai: ["gpt-5.6-luna", "gpt-5.6-sol"],
    anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-5"]
  },
  max_active_cases: 20,
  max_total_cases: 50,
  max_prompt_bytes: 40_000,
  max_request_messages: 20,
  max_request_template_bytes: 160_000,
  max_context_bytes: 100_000,
  max_variables_bytes: 50_000,
  max_response_format_bytes: 40_000,
  max_generation_config_bytes: 4_000,
  max_import_bytes: 2_000_000,
  max_output_tokens: 8_192

config :silent_regression, :capture_domain,
  attempt_lease_seconds: 900,
  max_calls_per_run: 200,
  max_retry_limit: 2,
  max_samples_per_case: 10

config :silent_regression, :monitor_operations,
  repeated_authentication_failure_limit: 2,
  dispatcher_batch_size: 100

config :silent_regression, :rate_limits,
  login: [limit: 10, window_seconds: 900],
  invitation_acceptance: [limit: 10, window_seconds: 3600],
  credential_validation: [limit: 20, window_seconds: 3600],
  run_authorization: [limit: 60, window_seconds: 3600]

# Development-only default. Production must replace this in runtime configuration before launch.
config :silent_regression, :rate_limit_hmac_key, "silent-regression-development-rate-limit-key"

# Development-only default. Production must replace this before launch. It is
# used only to make non-reversible, content-free workspace deletion receipts.
config :silent_regression,
       :deletion_receipt_hmac_key,
       "silent-regression-development-deletion-receipt-key"

# Provider credentials are write-only inputs. Phoenix filters matching keys at
# every depth before request parameters are logged.
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "api_key",
  "authorization",
  "system_prompt",
  "user_prompt_template",
  "frozen_context",
  "input_variables",
  "input_variables_json",
  "expectation",
  "expectation_json",
  "case_import",
  "output",
  "output_text",
  "contract",
  "root",
  "rules",
  "alternatives",
  "fact_alternatives",
  "source_ids",
  "allowed_values"
]

# Configure the endpoint
config :silent_regression, SilentRegressionWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SilentRegressionWeb.ErrorHTML, json: SilentRegressionWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SilentRegression.PubSub,
  live_view: [signing_salt: "GcaLMlVq"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :silent_regression, SilentRegression.Mailer, adapter: Swoosh.Adapters.Local

config :silent_regression,
       :notification_email_from,
       {"Silent Regression", "alerts@silent-regression.local"}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  silent_regression: [
    args:
      ~w(js/app.tsx --bundle --chunk-names=chunks/[name]-[hash] --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=./js --resolve-extensions=.tsx,.ts,.jsx,.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :inertia,
  endpoint: SilentRegressionWeb.Endpoint,
  static_paths: ["/assets/js/app.js", "/assets/css/app.css"],
  default_version: "1",
  camelize_props: true,
  raise_on_ssr_failure: config_env() != :prod

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  silent_regression: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
