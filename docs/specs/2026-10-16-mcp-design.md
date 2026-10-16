# The app as an MCP server, signed in through Pocket ID

Status: draft for the owner's approval, 2026-10-16.

## Why

The owner wants Claude (Claude Code, claude.ai, the phone app) to be a coach: read
progress, keep the coach's memory, set goals, plan, add and edit workouts. Claude is not a
client of the in-app coach; it *is* a coach, working from the same facts, rules and tools.
The in-app coach stays as it is, and both share one memory, one set of goals and one
library, so either can pick up where the other left off.

The intelligence the in-app coach has lives in three places, and MCP exposes each:

- **What it knows:** `Coach.AgentPrompt.context/2` (memory, goals, level, landmarks, recent
  sessions, the next slot of the week). The `get_coach_context` tool returns exactly that.
- **How it coaches:** `Coach.Voice.text/0`, the level rules from `Levels`, and the
  planner's task. Served as an MCP **prompt**, `coach`, built from the same functions, so
  a change to the voice changes both coaches.
- **What it can do:** the scoped `Coach.Tool` modules. Validation, rationale checks and the
  plan compiler run on the server, so Claude cannot store a workout the app could not
  run or a goal the app would not accept.

## Shape

Same model as kcal: **the app is only a resource server; Pocket ID is the authorization
server.** No authorize or token endpoints of our own.

```
Claude ──(OAuth 2.1, PKCE)──▶ Pocket ID ──▶ access token (JWT, aud = burpee MCP)
Claude ──POST /mcp, Authorization: Bearer <JWT>──▶ BurpeeTrainer
                                                   ├─ verify iss, aud, exp, signature (JWKS, cached)
                                                   ├─ sub → existing user (oidc_sub), else 401
                                                   └─ JSON-RPC: initialize, tools/list, tools/call
```

- `GET /.well-known/oauth-protected-resource` (RFC 9728): `resource` = the MCP URL,
  `authorization_servers` = [the Pocket ID issuer], `scopes_supported`.
- A 401 from `/mcp` carries `WWW-Authenticate: Bearer resource_metadata="…"` so clients
  discover Pocket ID on their own.
- **Pocket ID setup (once, by hand):** an OIDC client for Claude, with the callback URL
  that claude.ai and Claude Code use. Its client ID and secret go into the connector's
  advanced settings. The app's config adds `MCP_OIDC_AUDIENCE` (the issuer is the one
  login already uses).
- **No new users.** Unlike kcal, a token whose `sub` matches no user is refused: the
  account is created by signing in to the app, the same as today.
- **Transport:** Streamable HTTP, stateless, JSON responses only (no SSE). The endpoint is
  a plain Phoenix controller in its own pipeline (no session, no CSRF), and every call
  runs as `Scope.for_user(user)`.

## Tools

Writes apply directly (the owner's choice). Claude asks before each tool call anyway.
Deletes are their own tools and never side effects of something else.

| Tool | Does |
|---|---|
| `get_week` | this week's minutes against 80, the window (done and left), streak, level |
| `query_history` | sessions matching filters (below), newest first, paged |
| `history_stats` | per-week or per-month totals for the same filters (below) |
| `get_progress` | the gauges and per-type trend Progress shows |
| `list_memory` / `update_memory` | the coach's notes; add/forget through `Memory.apply_ops` (same guard: ≤5 ops, 160 chars, ≤20 notes) |
| `list_goals` / `set_goal` / `confirm_goal` / `dismiss_goal` | goals per burpee type |
| `list_workouts` | the library: name, type, reps, minutes, pacing style, pace |
| `get_workout` | one workout in full (see "How a workout is described") |
| `create_workout` / `edit_workout` / `archive_workout` | take the shape `get_workout` returns; compiled and checked by the app, so a plan from Claude can always be run |
| `log_session` / `edit_session` / `delete_session` | a workout done away from the phone; correct a session's feedback (notes, tags, mood, limiter, preference, energy, heat); delete one |
| `get_coach_context` | what the in-app coach sees before it answers (above) |
| `plan_next_workout` | the next slot of the week, then `select_workout` / `propose_workout` as the planner uses them: the pick and its one-sentence rationale land on Home |

There is no tool for messaging the in-app coach: Claude coaches. What Claude learns about
the athlete goes into the shared memory with `update_memory`, so the in-app coach knows it
too.

### Querying history

`query_history` filters on any of: date range (`from`, `to`, local dates), `burpee_type`,
`workout` (plan id or name), `tags` (any of), `capture_mode` (tracked, timed, logged),
`min_reps` / `max_reps`. Each session returns date, type, workout name, reps planned and
done, minutes planned and done, pace, reps per 20 minutes, pace consistency, sets
completed, mood, limiter, preference, context flags, tags and both notes. Pages of 50 with
a cursor; no cap on how far back.

`history_stats` groups the same filters by `week` or `month` and returns, per period and
type: sessions, minutes, reps, best reps per 20 minutes, average pace, and whether the
week met 80 minutes. It reuses `History` and `Stats.Series`, so the numbers equal
Progress's. The in-app coach's `history` tool (26 weeks, 200 sessions) is unchanged.

### How a workout is described

The app stores a workout as an exact definition: its sets in order (reps, seconds per rep,
seconds of movement) and the rests between them, summing to the workout's length to the
microsecond. Claude writes the authoring form the in-app coach writes, and the app does
the arithmetic:

- **What it asks for** (`WorkoutRequest`): burpee type, target reps, target duration,
  pacing style (`even`: a rest after every rep; `unbroken`: reps back to back in sets),
  recovery, timed rests, requested pace.
- **The layout:** a name, a one-sentence rationale, and phases of sets with rest
  weights; `RestFitter` shares the spare time between the gaps by weight.

`create_workout` and `edit_workout` take that form and run the in-app coach's pipeline
(`WorkoutRequest.new`, `RestFitter.fit`, `WorkoutDefinition.new`, `PlanCompiler.compile`,
`WorkoutRequest.validate_definition`), then publish with `Workouts.commit_approved_workout`.
A workout the app could not run is refused with the fitter's reason ("phase 1 needs 22:30
of movement but only 20:00 is available").

`get_workout` returns the exact `definition`, a one-line `summary` ("10 sets of 15, 6 s
per rep (4.5 s moving), 33.3 s between sets, 20 min"), and `editable`: the same workout
in the authoring form, one phase whose rest weights are the stored rests. Sending
`editable` back unchanged stores an equal workout; Claude changes only the fields it
means to. A definition with a rest first or last has no authoring form (`editable` is
null) and can only be replaced.

Published workouts are never changed in place: `edit_workout` is
`Workouts.replace_plan/4`, one transaction that publishes the new workout, moves every
Home selection of the old one to it (bumping the Home revision), and archives the old
one. Sessions keep their own snapshot. Built-in workouts cannot be edited;
`create_workout` makes the athlete's own version.

The format itself is an MCP **resource**, `burpee://workout-format`, generated from
`WorkoutRequest.json_schema/0`, `WorkoutLayout`, and `Levels`; a test fails if a field or
value is left unexplained.

### Correcting a session

A completed session is the app's permanent record, locked by a database trigger, and
personal bests are saved from it. Only the athlete's feedback can change afterwards:
notes, tags, mood, limiter, preference, and the energy and heat flags (a migration
narrows the trigger to allow exactly these). Reps, time and date stay locked; to fix
those, Claude deletes the session and logs it again.

### Living next to the in-app coach

The in-app coach runs on queued jobs. Without these rules they would undo Claude's work:

1. **The planner never replaces a planned slot.** `PlanNextWorkoutJob` is scheduled for
   midnight after a session and today replaces whatever Home shows. A slot whose selection
   was set by Claude or the owner is marked (`planned_by`: `owner`, `claude`, `coach`);
   the job cancels with `:already_planned` unless the mark is `coach` or empty.
2. **Claude's changes do not queue the memory job.** Sessions logged or edited through MCP
   skip `MemoryJob`; Claude keeps the memory itself. Sessions saved in the app still queue
   it.
3. **The coach's note follows every change.** Logging, editing and deleting a session
   through MCP queue `SummaryJob`, as completing one in the app does. Logging also queues
   `PlanNextWorkoutJob` (subject to rule 1); editing and deleting do not re-plan.
4. **Memory changes from both coaches go through `Memory.apply_ops`**, one transaction
   each, under the same guard. An op on a note the other coach already forgot is skipped,
   not an error.

Each tool is a `BurpeeTrainer.Coach.Tool` module (name, description, JSON schema, `call/3`),
so arguments are validated before anything runs. The existing coach tools that only read
(history, goals, library) are reused as is.

**New in the contexts:** logging a session by hand (`source_kind: :manual`,
`capture_mode: :logged`, which the schema already allows), correcting a session's
feedback, and `Workouts.replace_plan/4`. Deleting
reuses `Workouts.delete_session/2`, which Progress already uses. Changes from MCP
broadcast on the same PubSub topics, so an open app updates live.

## Who has the in-app coach

The in-app coach (the model behind the planner, the weekly note, memory upkeep and the
chat) is a permission, granted in Pocket ID by a **custom claim on a group**, the way
Pocket ID's own client examples grant app roles. Users without it coach through Claude
instead, and the app never calls the model for them.

- **Pocket ID:** groups name who may use what: `burpee` (allowed on the app's client and
  on Claude's BurpeeTrainer client), `burpee-coach` with the custom claim
  `burpee_coach` = `true`. The app reads the claim, never a group name, so a group can be
  renamed or a second group can grant the coach without touching the app.
- **Config:** `COACH_CLAIM`, default `burpee_coach`.
- **At sign-in** the app sets `users.coach_enabled` = the ID token's claim is `true` (the
  boolean or the string). It is re-read at every sign-in; losing the claim takes effect
  at the next one. The migration sets existing users to `true`, so nobody loses the
  coach before their next sign-in; the claim must be on the group before then.
- **One gate:** `Coach.enabled?(scope)`, checked in `Coach.Client.chat/2`, the one place
  the app calls the model. A user without the coach gets `:provider_unavailable` there,
  before any budget is reserved, which every caller already handles: the planner cancels
  and Home keeps its fallback workout (`Workouts.ensure_home_selection/2`), the summary,
  memory and insight jobs change nothing, and workout design and the chat say the coach
  is unavailable. Jobs may still be queued; they make no call.
- **Home without the coach** keeps the coach section, without the message box or reply
  pills. It shows what Claude left: the note Claude wrote (`set_coach_note`), the
  workout Claude planned and its reason, this week's window, and memory changes as
  "Noted:" lines. With nothing from Claude yet, the section is hidden.
- **Claude tool:** `set_coach_note` writes the coach's note and look back
  (`Coach.Summary` `text` and `review`, same length limits as the summary job). It is
  available to every user; for a user with the in-app coach, the next summary job
  rewrites it.
- **Who may use the app and MCP** is decided in Pocket ID (each client's allowed
  groups), not in the app. The Claude client is BurpeeTrainer's own, never shared with
  another app, so its `aud` keeps tokens from being accepted across apps.

## Out of scope

- Our own OAuth server, dynamic client registration, API keys.
- Starting or controlling a live workout from Claude.
- Videos and pose traces.

## Tests

- Token verification: wrong issuer, wrong audience, expired, bad signature, unknown `sub`,
  all 401 with the `WWW-Authenticate` header. Tests sign their own JWTs against a JWKS
  stub; no network.
- JSON-RPC: `initialize`, `tools/list` matches the modules, unknown tool, invalid
  arguments are refused before any effect.
- Each tool is scoped: one user can never read or change another's data.
- The `coach` prompt contains `Voice.text/0` and the current landmarks.
- `get_coach_context` equals `AgentPrompt.context/2` for the same scope.
- `query_history` filters compose, and paging returns each session exactly once.
- `history_stats` equals Progress's weekly minutes and best reps for the same sessions.
- `get_workout` → `edit_workout` with no changes stores an equal workout; a workout
  whose reps cannot fit is refused with the reason.
- The planner job cancels for a slot planned by Claude, and still plans an unmarked one.
- A session logged through MCP queues the summary and planner jobs, not the memory job.
- Sign-in with the claim `true`, `"true"`, absent or `false` sets `coach_enabled`
  accordingly; `COACH_CLAIM` picks the key.
- `Client.chat/2` makes no call and reserves no budget for a user without the coach.
- A user without the coach: Home shows the section without the message box or replies,
  with Claude's note, and hides it (and the Done toggle) when there is nothing.
- One flow test: Claude-style call sequence adds a goal and a memory note, and Home shows
  them.
