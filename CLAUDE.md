# BurpeeTrainer — CLAUDE.md

## Tech stack

- Elixir / Phoenix 1.8, LiveView 1.1, Ecto + SQLite (`ecto_sqlite3`)
- Tailwind CSS and esbuild
- Server-rendered LiveView with browser hooks; no React or Node server

## Module map

| Module | Responsibility |
|---|---|
| `BurpeeTrainer.Accounts` / `BurpeeTrainer.Accounts.User` | Local OIDC-scoped user records and identity resolution |
| `BurpeeTrainer.Auth.Oidc` | OIDC provider integration |
| `BurpeeTrainer.Coach` | User-scoped workout authoring, review, and approval |
| `BurpeeTrainer.Coach.{Context, DesignSession, DesignEntry, Guidance, Memory}` | Durable authoring context, guidance, and coach memory |
| `BurpeeTrainer.Coach.{Catalog, Policy, CatchUpPolicy, AuthoritativeSession}` | Deterministic workout selection and policy facts |
| `BurpeeTrainer.Coach.{Client, WorkoutRequest, WorkoutConfiguration, WorkoutGuidance}` | Validated authoring requests and provider boundary |
| `BurpeeTrainer.CoachReconciler` / `BurpeeTrainer.CoachSupervisor` | Supervised local recommendation reconciliation |
| `BurpeeTrainer.PlanCompiler` and `BurpeeTrainer.PlanCompiler.*` | Validation and compilation of workout definitions into programs |
| `BurpeeTrainer.Workouts` and `BurpeeTrainer.Workouts.*` | Workout library, recommendation selection, immutable session snapshots, finalization, and pose capture persistence |
| `BurpeeTrainer.Videos` / `BurpeeTrainer.Workouts.WorkoutVideo` | Video workout lookup and session sources |
| `BurpeeTrainer.Goals`, `BurpeeTrainer.Levels`, `BurpeeTrainer.Milestones`, `BurpeeTrainer.Scoring`, `BurpeeTrainer.Stats.Series` | Progress and scoring domain queries |
| `BurpeeTrainer.UserTime` | User-local date and time calculations |
| `BurpeeTrainerWeb.OverviewLive` | Authenticated Home, authoring review, chooser, Coach, and History surface |
| `BurpeeTrainerWeb.SessionLive` / `BurpeeTrainerWeb.VideoLive.Show` | Plan and video session runners |
| `BurpeeTrainerWeb.HomeHistory` / `BurpeeTrainerWeb.HomeDayBoundary` | Home history presentation and local-day scheduling |
| `BurpeeTrainerWeb.Components.*` | Shared layout, Home, History, Coach, workout, and session components |
| `BurpeeTrainerWeb.Router` | OIDC, authenticated Home/session/video, pose upload, and video stream routes |

## Data and authentication boundaries

- A completed session keeps an immutable program or video snapshot; later edits or archival do not rewrite History.
- Authoring proposals are reviewed before approval. Selection is distinct from approval.
- Auth is OIDC-only. `Accounts.resolve_oidc_identity/2` resolves a subject first, adopts an unlinked matching username, and rejects a username bound to another subject. See `docs/oidc-setup.md`.
- SQLite has no array column type; persisted collections use JSON text where the schema requires it.

## UI rules

See `UI.md` for the full visual specification. Use the application palette and existing Phoenix components; do not add inline scripts to HEEx templates.

## Testing policy

Keep a test only when it would fail on a real user-visible regression, data-integrity or ownership violation, or pure-core invariant. Delete styling-, copy-, CSS-, or markup-only assertions, private/internal call-shape checks, mocked forwarding behavior, removed-code coverage, and full-flow duplicates without a distinct failure mode. Keep accessibility contracts even when they use markup or styling assertions: roles, ARIA labels and screen-reader behavior, keyboard operation, reduced-motion behavior, and 44px target-size coverage are user-visible regression protection.

Property tests remain for `PlanCompiler` and `WorkoutRequest` validation. Provider-dependent tests use the local recorded-response plug and never make paid calls. The core-flow suite is documented in `TESTING.md`.

## Precommit

The integration gate, not this docs lane, runs:

```bash
ERL_FLAGS='+S 4:4' MIX_ENV=test mix precommit
```
