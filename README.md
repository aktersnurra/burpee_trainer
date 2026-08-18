# BurpeeTrainer

A personal burpee training application for designing structured workouts, running timer- or camera-tracked sessions, and reviewing progression over time.

Built with Phoenix LiveView, SQLite, Tailwind CSS, and lightweight browser hooks. The deployed application is available at [burpee.gustafrydholm.xyz](https://burpee.gustafrydholm.xyz).

## Features

- **Durable workout library** — `workout_plans` is canonical. Valid drafts can be refined in natural language, explicitly published, copied, or deleted; published plans are immutable, reusable, startable, and archivable.
- **Safe LLM authoring** — create and refine each make one bounded `Req` request. Valid output is persisted only as a draft; invalid output persists nothing. A generated recommendation is published and selected only after **Use this workout**; rejection deletes the alternative draft.
- **Deterministic coaching** — Home projects the weekly target, done-today state, fallback, and recommendation pointer from persisted facts. A supervised transient reconciler recovers missing recommendations without durable jobs, attempts, leases, checkpoints, or outboxes.
- **Immutable execution** — Start creates the exact `started` session ID and stores a plan Work/Rest or video snapshot. Resume reads that snapshot; completion updates the same row exactly once and remains offline-capable during the runner.
- **Stable History and Stats** — completed views use session snapshots, so later plan archival or video changes cannot rewrite the workout that was performed.
- **Live session runner** — terminal-active timing, audio cues, wake lock, pause/resume, breathing, count-in, and optional BlazePose rep tracking with timer fallback.
- **Single-user authentication** — bcrypt password hashing with all application data scoped to the user.

## Stack

- Elixir `~> 1.19` and Phoenix 1.8 with LiveView
- Ecto with SQLite via `ecto_sqlite3`
- Tailwind CSS v4
- Vanilla JavaScript modules and LiveView hooks
- Chart.js for charts
- bcrypt for password hashing

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

### Create the user

BurpeeTrainer currently uses a single-user setup. Create the initial account with:

```bash
mix burpee_trainer.create_user
```

The task prompts for a username and password, hashes the password through the normal Accounts boundary, and refuses to create a second user when one already exists.

Create the user before attempting to log in to a fresh database.

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
```

`mix precommit` compiles with warnings treated as errors, checks for unused dependencies and formatting, and runs ExUnit. The deletion-first migration rehearsal and authenticated browser procedure are documented in `TESTING.md` and `docs/testing/workout-session-e2e.md`.

## Production configuration

Production releases read their runtime configuration from environment variables.

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_PATH` | Yes | Persistent SQLite database path outside the replaceable release directory. |
| `SECRET_KEY_BASE` | Yes | Cookie and application secret. Generate with `mix phx.gen.secret`. |
| `PHX_HOST` | Yes in practice | Public hostname used in generated URLs. |
| `PHX_SERVER` | Yes for a release | Set to `true` so the Phoenix endpoint starts. |
| `PORT` | No | HTTP port; defaults to `4000`. |
| `POOL_SIZE` | No | SQLite connection pool size; defaults to `5`. |
| `DNS_CLUSTER_QUERY` | No | Optional DNS-based cluster discovery query. |
| `LLM_PROVIDER_URL` | For LLM authoring | Provider endpoint for natural-language create/refine and recommendation generation. |
| `LLM_PROVIDER_API_KEY` | For LLM authoring | Provider credential. If either provider value is absent, LLM HTTP is disabled and deterministic fallback remains usable. |
| `LLM_PROVIDER_MODEL` | No | Provider model; defaults to `openai/gpt-5-mini`. |
| `LLM_PROVIDER_TIMEOUT_MS` | No | Request timeout from 1,000–60,000 ms; defaults to 20,000. |

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
```

Deployment infrastructure is deliberately not part of this tree; the deployment machine supplies it through the private infra symlink described above.
