# BurpeeTrainer — CLAUDE.md

## Tech stack

- Elixir / Phoenix 1.8, LiveView 1.1, Ecto + SQLite (`ecto_sqlite3`)
- Tailwind CSS and esbuild
- Server-rendered LiveView with browser hooks; no React or Node server

## Module map

| Module | Responsibility |
|---|---|
| `BurpeeTrainer.Accounts` / `BurpeeTrainer.Accounts.{User, Scope}` | Local OIDC-scoped user records, identity resolution, and the `%Scope{}` every user-facing context function takes |
| `BurpeeTrainer.Auth.Oidc` | OIDC provider integration |
| `BurpeeTrainer.Home` / `BurpeeTrainer.Home.{Facts, State}` | Loads Home facts once and derives exactly one Home state (pure, property-tested) |
| `BurpeeTrainer.History` | Completed-session History queries and results |
| `BurpeeTrainer.Coach` | User-scoped workout authoring: layout request, fitting, review, and approval by approval key |
| `BurpeeTrainer.Coach.{RestFitter, WorkoutLayout, WorkoutRequest, WorkoutConfiguration, WorkoutGuidance, AuthoringPrompt}` | LLM layout schema and prompt, confirmed requests, and the pure rest fitter that computes exact rests |
| `BurpeeTrainer.Coach.{Agent, AgentPrompt, Tool, Tools.*}` | Bounded tool-using coach for the planner and Coach-page surfaces |
| `BurpeeTrainer.Coach.RepCeiling` | The most reps the planner may plan, designed or picked: 10% above the recent best, or the next level without a recent session |
| `BurpeeTrainer.Coach.{Selector, SelectionRationale}` | Plans a slot with a decision model first (pick a fitting workout or `create_new`, then the coach designs one), and the template rationale for a picked workout |
| `BurpeeTrainer.Coach.{Voice, Rationale}` | The one athlete-facing voice every prompt starts with, and the check the planner tools apply to a rationale before it reaches Home |
| `BurpeeTrainer.Coach.{Memory, Memory.Ops, MemoryJob, PlanNextWorkoutJob}` | The coach's notes about the owner (one fact per row, guarded by `Memory.Ops`, shared with Claude), the job that keeps them after an exchange or session, and the job that plans the next workout (never replacing a slot the owner or the MCP client planned: `planned_by`) |
| `BurpeeTrainer.Coach.{Summary, SummaryJob}` | The owner's two-sentence progress summary (validated against metrics, deterministic fallback) and the job that refreshes it after a completion or a confirmed goal, and when the app opens with a summary from an earlier week |
| `BurpeeTrainer.Coach.{Client, Ledger, LlmCall}` | Provider boundary (`chat/2`, and `decide/3` for the Decisions API) and the per-call ledger with daily budgets for automated and owner-started calls |
| `BurpeeTrainer.Scim` / `BurpeeTrainer.Scim.Group` / `BurpeeTrainerWeb.{ScimAuth, ScimController, ScimJSON}` | Pocket ID's SCIM provisioning at `/scim/v2`: users' access (`users.access` :: `:active \| :disabled \| :removed`, soft delete) and the coach group that sets `users.coach`; see `docs/specs/2026-10-20-scim-provisioning-design.md` |
| `BurpeeTrainer.Accounts.User.coach()` / `BurpeeTrainerWeb.HomeCoachComponents.coach/1` | Who coaches a user, `:app` (the app's model, for members of the Pocket ID coach group) or `:mcp` (through any MCP client, Claude or another), in `users.coach`; code matches on it, never a flag. For `:mcp` the app makes no model call, queues no coach job, and Home offers no authoring or chat, pointing to the MCP connection instead |
| `BurpeeTrainer.Mcp` / `BurpeeTrainer.Mcp.{Token, Sessions, Workouts, CoachPrompt, WorkoutFormat}` | The MCP server Claude coaches through: JSON-RPC dispatch, Pocket ID token checks, and the history, workout, prompt and format shapes Claude reads and writes |
| `BurpeeTrainer.Mcp.Tools.*` | The MCP tools, each a `Coach.Tool`; see `docs/specs/2026-10-16-mcp-design.md` and `docs/guides/mcp-setup.md` |
| `BurpeeTrainerWeb.{McpAuth, McpController, McpMetadataController}` | Bearer sign-in for `/mcp`, the endpoint, and its protected-resource metadata |
| `BurpeeTrainer.Coach.{Catalog, Policy, CatchUpPolicy, AuthoritativeSession}` | Deterministic workout selection and policy facts |
| `BurpeeTrainer.Coach.Policy.Week` | A training week as data: its target and catch-up days (the sign-up week is pro-rated with no catch-up); every weekly target reads it |
| `BurpeeTrainer.Insights` / `BurpeeTrainer.Insights.*` | Computed metrics, validated LLM narration with deterministic fallback, and the narration job |
| `BurpeeTrainer.Evals.*` / `mix burpee_trainer.eval` | Owner-run authoring evals with a mandatory call budget and response recording |
| `BurpeeTrainer.PlanCompiler` and `BurpeeTrainer.PlanCompiler.*` | Validation and compilation of workout definitions into programs |
| `BurpeeTrainer.Workouts` and `BurpeeTrainer.Workouts.*` | Workout library, Home selection (a starter until the first completed session, then the Steady 10 fallback), immutable session snapshots, completion, and pose capture persistence |
| `BurpeeTrainer.Videos` / `BurpeeTrainer.Workouts.WorkoutVideo` | Video workout lookup and session sources |
| `BurpeeTrainer.Goals`, `BurpeeTrainer.Levels`, `BurpeeTrainer.Milestones`, `BurpeeTrainer.Scoring`, `BurpeeTrainer.Stats.Series` | Progress and scoring domain queries |
| `BurpeeTrainer.UserTime` | User-local date and time calculations |
| `BurpeeTrainerWeb.HomeLive` | One LiveView for `/`, `/history`, and `/coach` (live actions `:home`, `:history`, `:coach`) |
| `BurpeeTrainerWeb.{HomeScreen, HistoryScreen, CoachScreen}` | Screen modules rendered by `HomeLive` |
| `BurpeeTrainerWeb.HomeAuthoring.Flow` | Pure authoring transitions: `update(model, event) -> {model, commands}`; work in flight is applied only while its `update_id` is current |
| `BurpeeTrainerWeb.{HomeAuthoring, HomeChooser, HomeWorkspace, HomeAdjustment, HomeWorkoutRequest, CreationParameters}` | Home authoring, chooser, and workspace behaviour |
| `BurpeeTrainerWeb.SessionLive` / `BurpeeTrainerWeb.VideoLive.Show` | Plan and video session runners |
| `BurpeeTrainerWeb.HomeDayBoundary` | Local-day boundary scheduling |
| `BurpeeTrainerWeb.Components.*` | Shared layout, Home, History, Coach, workout, and session components |
| `BurpeeTrainerWeb.Router` | OIDC, authenticated Home/History/Coach/session/video, pose upload, and video stream routes |

## Data and authentication boundaries

- A completed session keeps an immutable program or video snapshot; later edits or archival do not rewrite History.
- Authoring proposals are reviewed before approval. Selection is distinct from approval.
- Auth is OIDC-only. `Accounts.resolve_oidc_identity/2` resolves a subject first, adopts an unlinked matching username, and rejects a username bound to another subject. Setup is in `README.md` (Sign in).
- Pocket ID decides access: only `users.access == :active` passes `Auth` and `McpAuth`, and SCIM keeps it current. Removing a user never deletes their data.
- SQLite has no array column type; persisted collections use JSON text where the schema requires it.

## UI rules

See `docs/ui.md` for the visual system. Use the application palette and existing Phoenix components; do not add inline scripts to HEEx templates.

## Testing policy

Keep a test only when it would fail on a real user-visible regression, data-integrity or ownership violation, or pure-core invariant. Delete styling-, copy-, CSS-, or markup-only assertions, private/internal call-shape checks, mocked forwarding behavior, removed-code coverage, and full-flow duplicates without a distinct failure mode. Keep accessibility contracts even when they use markup or styling assertions: roles, ARIA labels and screen-reader behavior, keyboard operation, reduced-motion behavior, and 44px target-size coverage are user-visible regression protection.

Property tests remain for `PlanCompiler` and `WorkoutRequest` validation. Provider-dependent tests use the local recorded-response plug and never make paid calls. The core-flow suite is documented in `docs/testing.md`.

## Documentation

Committed documentation lives in `docs/` (index: `docs/README.md`):

- `docs/specs/` — dated design specs, `YYYY-MM-DD-<topic>-design.md`. New specs go here.
- `docs/plans/` — implementation plans in progress, `YYYY-MM-DD-<topic>.md`. Delete a plan
  once it is complete; version control keeps it.
- `docs/guides/` — runbooks and checklists.
- `docs/ui.md` (visual system) and `docs/testing.md` (test policy and core flows).

Local notes, reviews, evidence and scratch documents go in the git-ignored `.docs/`. Delete
a spec when the code it describes is removed.

## Precommit

Run before marking work done:

```bash
ERL_FLAGS='+S 4:4' MIX_ENV=test mix precommit
```
