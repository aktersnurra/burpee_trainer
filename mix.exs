defmodule BurpeeTrainer.MixProject do
  use Mix.Project

  def project do
    [
      app: :burpee_trainer,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Every compile of our code fails on a warning, not only precommit and CI.
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      usage_rules: usage_rules(),
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # `mix usage_rules.sync` writes these into AGENTS.md between its markers. Only deps we
  # trust are listed (never :all), and no dependency-provided skills are pulled in.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        # Its own rules (docs search), plus its built-in Elixir and OTP rules.
        :usage_rules,
        "phoenix:elixir",
        "phoenix:phoenix",
        "phoenix:ecto",
        "phoenix:html",
        "phoenix:liveview"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BurpeeTrainer.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, ci: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.12"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      # Req is the sole HTTP boundary for LLM provider calls.
      {:req, "~> 0.7"},
      {:oban, "~> 2.19"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.5"},
      {:tzdata, "~> 1.1"},
      {:remote_ip, "~> 1.2"},
      {:oidcc, "~> 3.9"},
      # Agent tooling, dev only and pinned by mix.lock: AGENTS.md rules from an
      # allowlist of trusted deps, and VibeKit's installer for the `mix ci` gate.
      {:usage_rules, "~> 1.2", only: :dev, runtime: false},
      {:igniter, "~> 0.8", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1.7", only: [:dev, :test], runtime: false},
      # The `mix ci` tools VibeKit added. Credo and Dialyxir are long established; ExSlop,
      # ExDNA and Reach are young and share one maintainer, so read their upgrades.
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm ci",
        "assets.pose"
      ],
      "assets.fonts": [
        "cmd --cd assets sh -c 'mkdir -p ../priv/static/assets/css/files && cp node_modules/@fontsource/geist/files/* ../priv/static/assets/css/files/'"
      ],
      "assets.pose": ["cmd scripts/prepare_pose_assets.sh"],
      "assets.fixture": ["esbuild burpee_trainer_fixture"],
      "assets.worker": ["esbuild burpee_trainer_pose_worker"],
      "assets.build": [
        "compile",
        "tailwind burpee_trainer",
        "assets.fonts",
        "assets.pose",
        "esbuild burpee_trainer",
        "assets.worker"
      ],
      "assets.deploy": [
        "tailwind burpee_trainer --minify",
        "assets.fonts",
        "assets.pose",
        "esbuild burpee_trainer --minify",
        "esbuild burpee_trainer_pose_worker --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --warnings-as-errors"
      ],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
