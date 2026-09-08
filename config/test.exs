import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :burpee_trainer, BurpeeTrainer.Repo,
  database: Path.expand("../burpee_trainer_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :burpee_trainer, BurpeeTrainerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "huMiWRpdLrjHA7H+QE14KSdIJwQ8ZdTq8Z/TNM4r/LRTO2ZK3Nqb2j/mi1BkUvGk",
  server: false

# In test we don't send emails
config :burpee_trainer, BurpeeTrainer.Mailer, adapter: Swoosh.Adapters.Test

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

# Dummy OIDC values. Tests never reach the network: the callback tests
# swap in a stub via :oidc_module.
config :burpee_trainer, :oidc,
  issuer: "https://pocket-id.test",
  client_id: "test-client-id",
  client_secret: "test-client-secret",
  redirect_uri: "http://localhost:4002/auth/oidc/callback"

# Never start the discovery worker in test. `oidcc`'s worker loads its
# configuration in a `handle_continue` after init, and its default
# `backoff_type` is `stop` — so against an unreachable issuer it would
# terminate and take the supervision tree with it.
config :burpee_trainer, :oidc_start_worker, false
