import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :silent_regression, SilentRegression.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "silent_regression_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :silent_regression, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :silent_regression, SilentRegressionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2A+4LH8lm709vJQ0tkmP2/o5movKiJbELEis0UjnWW58dE7kEX9yQ0wLPg9acIC+",
  server: false

# In test we don't send emails
config :silent_regression, SilentRegression.Mailer, adapter: Swoosh.Adapters.Test

config :silent_regression, :provider_adapters,
  openai: SilentRegression.Providers.FakeOpenAI,
  anthropic: SilentRegression.Providers.FakeAnthropic

# Fixed, test-only material keeps encryption assertions deterministic. Never
# reuse this key outside the automated test environment.
config :silent_regression, SilentRegression.Vault,
  json_library: Jason,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("dGVzdC1vbmx5LWtleS1tYXRlcmlhbC0zMi1ieXRlcyE="),
       iv_length: 12}
  ]

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
