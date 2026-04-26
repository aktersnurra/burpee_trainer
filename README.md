# BurpeeTrainer

A personal burpee training app with structured workout plans, live session tracking, and progression analytics. Built with Phoenix LiveView + SQLite, deployed at [burpee.gustafrydholm.xyz](https://burpee.gustafrydholm.xyz).

## Features

- **Workout plans** — three-layer editor with a solver that distributes reps, pacing, and rest periods automatically
- **Live session runner** — client-driven timer (no server ticks), Web Audio API beeps, no-screen-sleep
- **Two burpee styles** — 6-count and Navy Seal, each with their own archetypes and pace floors
- **Style recommender** — Bayesian scoring across nine workout archetypes, adjusted for mood and time of day
- **Progression tracking** — periodized 3-build/1-deload cycles, trend analysis, level landmarks
- **History & goals** — Chart.js performance charts, PR stats, level unlock badges
- **Video training** — Busy Dad Training videos served via nginx X-Accel-Redirect, log after watching

## Stack

- **Elixir / Phoenix 1.8** with LiveView
- **SQLite** via `ecto_sqlite3` — raw SQL throughout, no Ecto schemas
- **Tailwind CSS** — Scandinavian dark theme, electric blue accent
- **Vanilla JS hooks** — `SessionHook` (state machine + `requestAnimationFrame` clock), `ChartHook`, `VideoHook`
- **bcrypt** session auth, single-user

## Development

```bash
mix setup          # install deps, create and migrate DB, build assets
mix phx.server     # start at localhost:4000
iex -S mix phx.server  # with interactive shell
```

Create the initial user:

```bash
mix burpee_trainer.create_user
```

Run tests and pre-commit checks:

```bash
mix test
mix precommit      # compile --warnings-as-errors, unused deps, format, test
```

## Deployment

Deployed as a `mix release` behind nginx with TLS (certbot), managed by systemd.

```bash
HOST=burpee.gustafrydholm.xyz
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
rsync -avz --delete _build/prod/rel/burpee_trainer/ $HOST:/opt/burpee_trainer/
ssh $HOST "systemctl restart burpee_trainer"
```

See `deploy/README.md` for first-deploy server setup (systemd service, nginx config, env file).

## Project layout

```
lib/
  burpee_trainer/
    levels.ex           # pure: level derivation from session history
    plan_wizard.ex      # pure: PlanInput -> WorkoutPlan solver
    planner.ex          # pure: plan -> flat event timeline + warmup
    progression.ex      # pure: goal + sessions -> periodized recommendation
    style_recommender.ex
    style_generator.ex
    workouts.ex         # plans, sessions, style_performances context
    accounts.ex         # auth context
    goals.ex
    videos.ex
  burpee_trainer_web/
    live/
      overview_live.ex  # / — weekly streak + calendar
      session_live.ex   # /session/:plan_id
      history_live.ex   # /history
      goals_live.ex     # /goals
      log_live.ex       # /log
      plans_live/
    controllers/
      video_controller.ex  # X-Accel-Redirect auth for video files
assets/
  js/hooks/
    session_hook.js     # client-owned clock, state machine, beeps
    chart_hook.js
    video_hook.js
deploy/
  burpee_trainer.service
  nginx.conf
  deploy.sh
```
