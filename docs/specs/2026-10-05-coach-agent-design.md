# Coach agent: tools, notebook, goals, planned next workout

## Status

Sub-project 4 of `2026-10-05-coach-first-architecture-design.md`, written 2026-10-05.
Requires sub-projects 1–3. Decisions marked **(default)** were made by the spec author and are
open for owner review.

## Goals

- The coach plans the owner's next workout after every completed session, from history,
  goals and its notebook, so Home shows a ready workout with one Start button.
- The Coach page is a conversation: the owner tells the coach things; the coach updates its
  notebook and, only there, may propose a goal.
- Replace four memory/infrastructure mechanisms with two simple ones, and record every LLM
  call.

## Removed by this sub-project

| Removed | Replaced by |
|---|---|
| `Coach.Guidance`, `GuidanceEntry`, `coach_guidance_entries` table, classification calls | Notebook + Coach-page agent |
| `Coach.Memory`, `WorkoutMemory`, `coach_workout_memories` table, `MemorySubscriber`, `Workouts.Finalization` | Notebook (agent rewrites it after each session) |
| `Coach.Context`, `DesignSession`, `DesignEntry`, `workout_design_*` tables, append-only triggers | Prepared candidates in LiveView memory + approval key + LLM call ledger |
| `CoachReconciler`, `CoachSupervisor`, `CoachMemoryTaskSupervisor`, `CoachTaskSupervisor` | Oban jobs |
| `Coach.Client.complete/2` single-shot with fixed response kinds | `Coach.Client.chat/2` with tools and optional strict response format |

Tables are dropped in one migration after data that matters is carried over: existing
guidance entries' text and lasting summaries are appended to each user's initial notebook.

## Components

### LLM client

`Coach.Client.chat(messages, opts)` sends an OpenAI-compatible chat-completions request with
optional `tools` (function definitions with JSON-schema parameters) and optional
`response_format` (strict JSON schema). It returns
`{:ok, %{tool_calls: [%{id, name, arguments}], content: map() | String.t() | nil, usage: map()}}`
or `{:error, Error.t()}`. Existing limits stay: bounded body, timeout bounds, no redirects,
OpenRouter `require_parameters`. Every call is recorded in the ledger.

### LLM call ledger

Table `llm_calls`: `user_id`, `purpose` (`plan_next`, `coach_message`, `edit_request`,
`layout`, `insight`), `run_id` (UUID shared by calls of one agent run), `model`,
`prompt_tokens`, `completion_tokens`, `cost_usd` (from provider usage when present, else
null), `outcome` (`ok`, `tool_calls`, `invalid_response`, `provider_error`, `timeout`),
`duration_ms`, `inserted_at`. No prompt or response bodies are stored. **(default)** Per-user
rolling-24-hour caps are enforced from this table before any call, in two buckets: 25
automated calls (`plan_next`, `select`, `summary`, `memory`, `insight`) and 40 calls the owner starts
(every other purpose), plus a $0.25 cost cap across both. Over a cap returns
`:llm_budget_exhausted` and callers fall back as below.

### Agent loop

`Coach.Agent.run(scope, surface, input, opts)`:

- Builds the system prompt for the surface plus context: notebook, active and proposed
  goals, current level, the policy slot, and the last 10 completed sessions (summary rows).
  More history is available through tools. Prompt size is bounded by construction.
- Loops: call `Client.chat/2` with the surface's tools; execute returned tool calls in order;
  append results; stop on a final answer. Limits per run: 6 model calls, 3
  `propose_workout` calls. Exceeding a limit ends the run with `:agent_budget_exhausted`.
- Tool execution errors are returned to the model as tool results, never raised.

### Tools

Each tool is a module implementing `Coach.Tool` (`name/0`, `description/0`, `schema/0`,
`call(scope, args, run)`).

| Tool | Surfaces | Effect |
|---|---|---|
| `history(weeks)` | all | Read completed-session summaries (≤ 26 weeks) |
| `goals()` | all | Read active and proposed goals with progress |
| `library()` | planner | Read the owner's published plans (id, name, type, reps, duration) |
| `propose_workout(request_fields, layout)` | planner | Build a `WorkoutRequest` with type and duration fixed by the slot, fit and validate it (sub-project 2), save it as a published plan; returns plan id or the exact error |
| `select_workout(plan_id)` | planner | Make an owned or built-in published plan the slot's selection |
| `update_notebook(text)` | all | Replace the notebook (≤ 4,000 characters) |
| `propose_goal(fields)` | coach page only | Insert a goal with status `:proposed`; the owner confirms or dismisses it in the UI |

### Notebook

Table `coach_notebooks`: `user_id` (unique), `body` (≤ 4,000 characters), `updated_at`.
The Coach page "Details" section shows and edits the notebook directly; a manual edit takes
effect immediately for the next run. Agent writes compare `updated_at` and fail with
`:stale_notebook` if the owner edited it during the run (the run's other effects stand).

### Planning the next workout

- Oban (SQLite `Lite` engine) job `Coach.PlanNextWorkoutJob` with args `user_id`,
  `slot_key`. Enqueued after a session completes and at the day boundary when the new slot
  has no planner-made selection. Unique per `(user_id, slot_key)`; max 3 attempts with
  backoff.
- The job runs `Coach.Selector`. When a decision model is configured (`:decisions`, default
  `typesafe/jev-1.14` on OpenRouter's Decisions API), it first asks one Choice question:
  which of the saved and built-in workouts that fit the slot's burpee type and minutes, and
  stay within `Coach.RepCeiling`, suits the athlete, or `create_new`. A workout chosen with confidence at or
  above `min_confidence` (0.6) is selected with a `Coach.SelectionRationale` template, since
  the model writes no text. `create_new` at that confidence runs the agent on the `planner`
  surface with only `history`, `goals` and `propose_workout`. Without a decision model, when
  the decision call fails, or below `min_confidence`, the agent runs with all planner tools.
  The slot's selection is read before the decision call, and the planner never replaces a
  selection the owner or Claude made (`select_planned_workout` refuses it), so a choice made
  while the decision is out is kept. Every
  decision's probabilities are logged (`coach_selection_decided`) to tune the threshold.
- A planner reply that chose nothing is reminded once, then fails with `:no_selection`, and
  the job is cancelled rather than retried so it cannot spend the shared automated budget. Success leaves the slot with a selection and a rationale. If the job is exhausted, the provider is disabled, or the budget cap is
  hit, the existing deterministic fallback selection stays; Home never waits on the job.
- The planner's reps, designed or picked, stay within `Coach.RepCeiling`: the owner's recent
  best decides, at most 10% above their best 20-minute pace for the type in the last eight
  weeks, whatever their level. Only with no session of the type in that time does the level
  after their current one cap it. A longer slot (weekend catch-up) is compared at its
  20-minute-equivalent pace; easier is always allowed.

### Coach page conversation

- The new-info box sends the text to the agent on the `coach_page` surface. The reply text
  is shown under the box; proposed goals appear with Confirm and Dismiss. **(default)** No
  conversation transcript is stored; the notebook is the memory.
- Goals schema gains status `:proposed`. Confirm sets `:active`; Dismiss sets `:abandoned`.

### Authoring approval

Prepared candidates already live in LiveView assigns on the server. Approval recompiles and
revalidates the candidate deterministically and inserts the plan with a unique
`approval_key` (the prepared candidate's UUID) on `workout_plans`; a repeated approval
returns the existing plan. This replaces the design-session audit check.

## Error handling

Provider failures, budget exhaustion and invalid tool arguments never change the current
selection. Coach-page failures show "Coach unavailable. Try again later." and keep the text.

## Testing

- Agent loop tests with a recorded-response Req plug: tool-call sequences, budget limits,
  tool errors returned to the model, invalid responses.
- Tool tests against the database for ownership and validation (scoped queries).
- Job tests with `Oban.Testing`: enqueue on completion, uniqueness, fallback on failure.
- Full flows: complete a session → job runs with recorded responses → Home shows the planned
  workout with its rationale; Coach page message → notebook updated → goal proposed →
  confirmed → visible to the planner.
- Migration test: guidance text carried into notebooks; old tables dropped.
