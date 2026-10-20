# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :burpee_trainer,
  ecto_repos: [BurpeeTrainer.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :burpee_trainer, BurpeeTrainerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BurpeeTrainerWeb.ErrorHTML, json: BurpeeTrainerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BurpeeTrainer.PubSub,
  live_view: [signing_salt: "PDbU9DRi"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  burpee_trainer: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  burpee_trainer_pose_worker: [
    args:
      ~w(js/hooks/pose_worker.js --bundle --format=iife --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  burpee_trainer_fixture: [
    args:
      ~w(js/app_fixture.js --bundle --target=es2022 --outfile=../tmp/e2e-assets/app_fixture.js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  burpee_trainer: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Per-user rolling-24-hour LLM budgets; see BurpeeTrainer.Coach.Ledger. The cost cap is a
# backstop against a runaway loop: a call reserves its estimate until the provider reports
# its cost.
config :burpee_trainer, :llm_budget,
  automated_daily_cap: 25,
  user_daily_cap: 40,
  daily_cost_cap_usd: 0.25,
  reservation_cost_usd: 0.01

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :burpee_trainer, Oban,
  engine: Oban.Engines.Lite,
  repo: BurpeeTrainer.Repo,
  queues: [coach: 2],
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"17 * * * *", BurpeeTrainer.Analytics.TraceCleanupJob}]}
  ]
