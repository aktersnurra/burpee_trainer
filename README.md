# BurpeeTrainer

A personal burpee training application for designing structured workouts, running timer- or camera-tracked sessions, and reviewing progression over time.

Built with Phoenix LiveView, SQLite, Tailwind CSS, and lightweight browser hooks. The deployed application is available at [burpee.gustafrydholm.xyz](https://burpee.gustafrydholm.xyz).

## Features

- **Durable workout library** — `workout_plans` is canonical. Home's New and Edit flows prepare a review before saving a new immutable, reusable workout. Published workouts can be selected or archived without changing completed sessions.
- **Safe LLM authoring** — bounded `Req` extraction, planning, and repair produce a validated, audited review before a workout is saved. Home approval is provider-free: **Use workout** atomically saves and selects the reviewed plan; **Save to library** leaves today's selection unchanged. Swap also previews before Use. Cancellation preserves the selection, and Start remains separate (video reviews explicitly say **Start video**). Invalid or stale approvals do not publish a workout.
- **Workout-first coaching** — deterministic policy tracks the 80-minute week (pro-rated on sign-up) and suggests the next type and duration, including weekend catch-up. Oban plans after completed/logged sessions and at eligible day boundaries; Home stays startable while planning and updates when the result arrives. The normal offline-provider fallback is a type-appropriate 20-minute starter. The type split is a preference, not a weekly quota.
- **Evidence-based progression** — automatic saved-plan selection and generated proposals obey a deterministic decision from recent, authoritative same-movement sessions. Missing feedback repeats the demonstrated rate; two successful, equally paced prescriptions on separate days permit a 1–5 rep increase per 20 minutes. Early fatigue or missed targets ease off; late fatigue repeats the prescribed rate. Longer sessions are normalized, early finishes retain planned time, and the existing rep ceiling still applies. Manual choices remain unrestricted. This constrains recommendations; it is not evidence of real-model coaching quality.
- **Quick time choices** — 20/40-minute options prepare a local review without a provider call or changing the selection. Options cannot exceed the week's remaining time. They are visible during weekend catch-up, or when the workout is expanded, and build even short sets at the selected workout's normalized rate with recovery where time allows; the exact structure is reviewed before Use. Progress shows remaining weekly minutes and recent same-movement 20-minute equivalents without requiring both movements.
- **Immutable execution** — Start creates the exact `started` session ID and stores a plan Work/Rest or video snapshot. Resume reads that snapshot; completion updates the same row exactly once and remains offline-capable during the runner.
- **Stable History** — completed views use session snapshots, so later plan archival or video changes cannot rewrite the workout that was performed.
- **Live session runner** — terminal-active timing, audio cues, wake lock, pause/resume, breathing, count-in, and optional BlazePose rep tracking with timer fallback.
- **OIDC authentication** — Pocket ID sign-in with all application data scoped to the local user; identity linking preserves an existing account's history.

## Stack

- Elixir `~> 1.19` and Phoenix 1.8 with LiveView
- Ecto with SQLite via `ecto_sqlite3`
- Tailwind CSS v4
- Vanilla JavaScript modules and LiveView hooks
- Chart.js for charts
- OIDC via `oidcc` for Pocket ID authentication

## Local development

### Initial setup

From the repository root:

```bash
mix setup
```

`mix setup` installs Elixir and asset dependencies, creates and migrates the development database, prepares browser assets, and builds the application assets.

Start Phoenix at [http://localhost:4000](http://localhost:4000):

```bash
mix phx.server
```

For an interactive Elixir shell:

```bash
iex -S mix phx.server
```

### Database migrations

Apply migrations after pulling changes that add or modify database tables:

```bash
mix ecto.migrate
```

If Phoenix reports pending migrations, stop the server, run the command above, and restart it.

### Sign in

Configure the OIDC provider and sign in through Pocket ID. OIDC resolves a known subject first, adopts an unlinked matching username, or creates a new local user on first sign-in. Conflicting identity links are refused so existing history is not assigned to another account. Local fixture provisioning uses `Accounts.create_user/1`.

### Assets

Install or refresh frontend dependencies and generated pose assets:

```bash
mix assets.setup
```

Build development assets:

```bash
mix assets.build
```

Run the JavaScript tests:

```bash
cd assets
npm test
```

### Tests and project checks

Run the Elixir test suite:

```bash
mix test
```

Run the full project gates before finishing a change:

```bash
(cd assets && npm test)
mix assets.build
MIX_ENV=test mix precommit
MIX_ENV=test mix ci
```

`mix precommit` compiles with warnings treated as errors, checks for unused dependencies, formats, and runs ExUnit. `mix ci` then checks formatting and tests, strict Credo/ExSlop, Dialyzer, ExDNA (no clones), and Reach. Rehearse the schema migration against a copy of production with `scripts/migrations/rehearse_coach_first.exs`; the test policy and the authenticated browser procedure are in `docs/testing.md` and `docs/guides/workout-session-e2e.md`.

## Production configuration

Production releases read their runtime configuration from environment variables.

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_PATH` | Yes | Persistent SQLite database path outside the replaceable release directory. |
| `SECRET_KEY_BASE` | Yes | Cookie and application secret. Generate with `mix phx.gen.secret`. |
| `PHX_HOST` | Yes in practice | Public hostname used in generated URLs, and the app URL that names BurpeeTrainer in OpenRouter's logs (hidden from its public listings). |
| `PHX_SERVER` | Yes for a release | Set to `true` so the Phoenix endpoint starts. |
| `PORT` | No | HTTP port; defaults to `4000`. |
| `POOL_SIZE` | No | SQLite connection pool size; defaults to `5`. |
| `DNS_CLUSTER_QUERY` | No | Optional DNS-based cluster discovery query. |
| `OIDC_ISSUER` | Yes in production | Pocket ID issuer URL. |
| `OIDC_CLIENT_ID` | Yes in production | OIDC client identifier. |
| `OIDC_CLIENT_SECRET` | Yes in production | OIDC client secret; keep it outside the repository. |
| `OIDC_REDIRECT_URI` | No | Callback URI; defaults to `https://PHX_HOST/auth/oidc/callback`. |
| `LLM_PROVIDER_URL` | For built-in coaching | Provider endpoint for workout authoring, automatic planning, insights, summaries, and coach memory. |
| `LLM_PROVIDER_API_KEY` | For built-in coaching | Provider credential. If either provider value is absent, LLM HTTP is disabled and deterministic fallback remains usable. |
| `LLM_PROVIDER_MODEL` | No | Provider model; defaults to OpenRouter's `openai/gpt-6-luna`. |
| `LLM_PROVIDER_TIMEOUT_MS` | No | Request timeout from 1,000–60,000 ms; defaults to 20,000. |
| `DECISIONS_MODEL` | No | Decision model that picks the next workout before the planner designs one; defaults to `typesafe/jev-1.14`. |
| `DECISIONS_URL` | No | Decisions API endpoint; defaults to `https://openrouter.ai/api/alpha/decisions` when `LLM_PROVIDER_URL` is on OpenRouter, and uses `LLM_PROVIDER_API_KEY`. |
| `DECISIONS_ENABLED` | No | Set to `false` to plan with the LLM alone. |

For OpenRouter authoring, set `LLM_PROVIDER_URL` to `https://openrouter.ai/api/v1/chat/completions` and provision `LLM_PROVIDER_API_KEY` from your secret store. Both values are required to enable LLM HTTP; the default Luna model alone does not send requests. Override `LLM_PROVIDER_MODEL` only to select a different model supported by your configured endpoint. Keep provider credentials out of the repository. Eligible users' background jobs can call the provider after training, at an eligible day boundary, or to refresh a stale summary on open; authoring and coach messages can also call it. The call ledger enforces per-user daily call and cost budgets. Opening Home does not itself schedule workout planning. Failed or disabled coaching does not prevent starting an available workout.

The SQLite database and uploaded/runtime data must live in persistent paths managed by the target machine, not under the release directory that deployment replaces.

## Deployment

Deployment is intentionally owned by a separate private infrastructure repository. On the deployment machine, `./deploy` in this repository is a local symlink to that infra repository’s deploy command; the script itself is not tracked here.

Deploy to the NUC from the BurpeeTrainer repository root:

```bash
./deploy nuc
```

Deploy to another configured VPS/host by passing its infra target name:

```bash
./deploy <target>
```

If `./deploy` is missing on a deployment machine, restore the symlink using that machine’s private infra checkout rather than adding a deployment script to this repository:

```bash
ln -s /path/to/private-infra/deploy ./deploy
```

Target definitions, provisioning, release transfer/build details, migrations, service management, TLS, logs, and rollback procedures belong to the private infra repository. Treat that repository as the authoritative deployment documentation.

## Project layout

```text
lib/burpee_trainer/             Domain contexts, planning, compilation, persistence
lib/burpee_trainer_web/         Phoenix endpoint, controllers, components, and LiveViews
assets/css/                     Tailwind entry point and application styles
assets/js/                      LiveView client and browser hooks
priv/repo/migrations/           Ecto migrations
config/                         Compile-time and runtime environment configuration
scripts/                        Repository-owned asset and development helpers
test/                           ExUnit, LiveView, and domain tests
docs/                           Specs, plans in progress, guides, UI and testing rules
```

Deployment infrastructure is deliberately not part of this tree; the deployment machine supplies it through the private infra symlink described above.
