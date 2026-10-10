# Frictionless Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First use shows a ready workout, the sign-up week is pro-rated without catch-up, a validated two-sentence coach summary heads History and is the only way into Coach, and every screen shares one background, typeface and column.

**Architecture:** A pure `Coach.Policy.Week` value (target and catch-up days as data) replaces the 80-minute constant everywhere. Starter built-ins plus the existing Home selection machinery replace the first-use bootstrap. `Coach.SummaryJob` (Oban) computes metrics, asks the provider for one strict-JSON summary, validates it with the insights validator rules, and stores it in `coach_summaries`; `Coach.WeekCloseJob` (hourly cron) covers short weeks. Spec: `docs/specs/2026-10-10-frictionless-home-design.md`.

**Tech Stack:** Elixir, Phoenix LiveView 1.1, Ecto + SQLite, Oban 2.24 (Lite engine, Cron plugin), StreamData.

---

## Ground rules for the executor

- Workspace: `/Users/aktersnurra/projects/vibe/burpee_trainer.workspaces/coach-first`. jj only; each "Commit" step is `jj commit -m "<message>"` ending with the `Co-Authored-By` trailer. Never push.
- `T` = `env ERL_FLAGS="+S 4:4" MIX_ENV=test` (e.g. `T mix test`).
- Committed documentation lives in `docs/` (`specs/`, `plans/`, `guides/`, `ui.md`, `testing.md`); local notes and evidence go in the git-ignored `.docs/`.
- Test-first for every behaviour change: write the test, run it, see it fail for the stated reason, implement, see it pass.
- Locate code by module and function name, not line numbers.
- No `rescue`; no new flags or `if new_user?` branches: differences between weeks live in `Policy.Week` data (owner requirement).
- No paid LLM calls. Provider tests use `Req.Test` stubs (see `test/burpee_trainer/insights/narrator_test.exs`).
- The owner's dev server may be running from this workspace; do not stop it.

## File structure

| File | Responsibility |
|---|---|
| `lib/burpee_trainer/coach/policy/week.ex` (new) | Pure week value: start, target, catch-up days |
| `lib/burpee_trainer/coach/policy.ex` | Slot rules read `Week` instead of constants |
| `priv/repo/migrations/20261010000000_add_starter_workouts.exs` (new) | Two starter built-ins |
| `lib/burpee_trainer/workouts.ex` | Starter pinning; first-use bootstrap removed |
| `lib/burpee_trainer/home.ex`, `home/state.ex` | `:first_workout` removed; facts always ensure a selection |
| `lib/burpee_trainer/insights/metrics.ex` | Week targets from `Week`; trajectory and last-week metrics |
| `lib/burpee_trainer/insights/validator.ex` | `validate_summary/2` sharing the number rule |
| `lib/burpee_trainer/coach/summary.ex`, `coach/summary_job.ex`, `coach/week_close_job.ex` (new) | Summary storage, generation, week close |
| `priv/repo/migrations/20261010000100_create_coach_summaries.exs` (new) | `coach_summaries` |
| `lib/burpee_trainer_web/live/{home_live,home_authoring,home_screen,history_screen,coach_screen}.ex`, components | UI changes |
| `assets/css/adaptive_home.css`, `assets/css/app.css` | One background, Geist only |
| `docs/ui.md`, `CLAUDE.md`, `docs/testing.md` | Docs |

---

### Task 1: `Policy.Week` (pure)

**Files:** Create `lib/burpee_trainer/coach/policy/week.ex`; Test `test/burpee_trainer/coach/policy/week_test.exs`

- [x] **Step 1: Failing tests**

```elixir
defmodule BurpeeTrainer.Coach.Policy.WeekTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Coach.Policy.Week

  # 2026-10-05 is a Monday.
  test "a regular week has the full target and weekend catch-up days" do
    assert %Week{start: ~D[2026-10-12], target_sec: 4_800, catch_up_days: [6, 7]} =
             Week.new(~D[2026-10-09], ~D[2026-10-12])
  end

  test "the sign-up week is pro-rated by days left and has no catch-up days" do
    for {sign_up, target} <- [
          {~D[2026-10-05], 4_800},
          {~D[2026-10-08], 4_800},
          {~D[2026-10-09], 3_600},
          {~D[2026-10-10], 2_400},
          {~D[2026-10-11], 1_200}
        ] do
      assert %Week{target_sec: ^target, catch_up_days: []} = Week.new(sign_up, ~D[2026-10-05])
    end
  end

  property "only the sign-up week differs, and its target is 20 min per day left, capped at 80" do
    check all sign_up <- date_gen(), offset <- integer(-2..3) do
      sign_up_week = Date.beginning_of_week(sign_up)
      week_start = Date.add(sign_up_week, 7 * offset)
      week = Week.new(sign_up, week_start)

      if offset == 0 do
        days_left = Date.diff(Date.end_of_week(sign_up), sign_up) + 1
        assert week.target_sec == min(1_200 * days_left, 4_800)
        assert week.catch_up_days == []
      else
        assert week.target_sec == 4_800
        assert week.catch_up_days == [6, 7]
      end
    end
  end

  defp date_gen, do: map(integer(0..3_650), &Date.add(~D[2024-01-01], &1))
end
```

Weeks before the sign-up week (negative offsets) are regular: there is no history in them, and the constructor must not special-case them.

- [x] **Step 2: Run** — `T mix test test/burpee_trainer/coach/policy/week_test.exs` — FAIL (module missing).
- [x] **Step 3: Implement**

```elixir
defmodule BurpeeTrainer.Coach.Policy.Week do
  @moduledoc """
  One local training week. The sign-up week is pro-rated to 20 minutes per remaining day
  and has no catch-up days; every other week has the full target and weekend catch-up.
  Callers read the fields; nothing else asks whether a user is new.
  """

  @enforce_keys [:start, :target_sec, :catch_up_days]
  defstruct @enforce_keys

  @type t :: %__MODULE__{start: Date.t(), target_sec: pos_integer(), catch_up_days: [1..7]}

  @full_target_sec 4_800
  @daily_sec 1_200
  @weekend [6, 7]

  @spec new(Date.t(), Date.t()) :: t()
  def new(%Date{} = sign_up_date, %Date{} = week_start) do
    week(Date.beginning_of_week(sign_up_date) == week_start, sign_up_date, week_start)
  end

  defp week(true = _sign_up_week, sign_up_date, week_start) do
    days_left = Date.diff(Date.end_of_week(sign_up_date), sign_up_date) + 1
    %__MODULE__{start: week_start, target_sec: min(@daily_sec * days_left, @full_target_sec), catch_up_days: []}
  end

  defp week(false, _sign_up_date, week_start),
    do: %__MODULE__{start: week_start, target_sec: @full_target_sec, catch_up_days: @weekend}
end
```

- [x] **Step 4: Run** — PASS. **Commit** — `feat(policy): model the training week as data`

---

### Task 2: Policy and every target consumer read `Week`

**Files:** `lib/burpee_trainer/coach/policy.ex`, `lib/burpee_trainer/history.ex`, `lib/burpee_trainer/insights/metrics.ex`, `lib/burpee_trainer_web/components/home_history_components.ex`; tests `test/burpee_trainer/coach/policy_test.exs`, metrics tests.

- [x] **Step 1: Failing tests** in `policy_test.exs` (use `user_fixture/1` with `"timezone"`, then set `inserted_at` with `Repo.update_all` to the sign-up instant; evaluate `Policy.required_slot/2` at a chosen `now`):
  - signed up Saturday 2026-10-10 09:00 local, `now` = same day → `weekly_target_sec == 2_400`, `strategy == :standard`, `duration_sec == 1_200`;
  - signed up Friday → target 3_600; Sunday → 1_200;
  - signed up three weeks earlier, `now` Saturday with nothing done → target 4_800, `strategy == :catch_up`, `duration_sec == 4_800` (unchanged behaviour);
  - DST: `America/Los_Angeles`, sign-up Saturday 2026-03-07 (week containing the 2026-03-08 change) → target 2_400.
  - Property: for a generated sign-up date in the past year and a `now` within 0..20 days after it, `slot.duration_sec <= slot.remaining_sec`, and in the sign-up week `slot.strategy == :standard` and `slot.duration_sec <= 1_200`.
- [x] **Step 2: Run** — FAIL (target is the constant).
- [x] **Step 3: Implement in `Policy.required_slot/2`:**
  - `week = Week.new(UserTime.local_date(user.inserted_at, context.timezone) |> elem(1), context.week_start)` (check `UserTime.local_date/2`'s return shape and use it the way `Insights.Metrics.compute/4` does).
  - Replace `@weekly_target_sec` with `week.target_sec` (remaining, week_complete, `weekly_target_sec:` in the slot map) and `Date.day_of_week(context.date) in [6, 7]` with `Date.day_of_week(context.date) in week.catch_up_days`. Delete `@weekly_target_sec`; change the `@type slot` field to `weekly_target_sec: pos_integer()`.
  - Nothing else in `Policy` changes. In particular no conditional on the week's origin.
- [x] **Step 4: Remaining hard-coded targets** (each gets a focused failing test first, then the fix):
  - `History` weeks (`target?: seconds >= 4_800`): compute `Week.new(sign_up_date, date).target_sec` per week; `History` already has the user and context.
  - `HomeHistoryComponents.day_bar_height/1` (`seconds * 100 / 4_800`): kept. It is the day chart's fixed 0–40–80 minute axis, not a target. Instead the week tooltip/aria-label and the completed-week count now read each week's `target_minutes` / `target?`.
  - `Insights.Metrics.compute/4`: add a `sign_up_date` argument (`compute/5`); `week.target_minutes` = `div(Week.new(sign_up_date, start).target_sec, 60)`; `streak/2` compares each week's total with that week's `target_sec`. Update `for_scope/4`/`for_session/4` callers to pass `UserTime.local_date(user.inserted_at, tz)`.
  - `grep -rn "4_800\|4800\|weekly_target\|80, :minutes" lib` then shows only `Week`, the slot field, the day-chart axis, the absolute minute colour legend and `CatchUpPolicy`'s 80-minute session cap.
- [x] **Step 5: Run** — `T mix test` → 0 failures. **Commit** — `feat(policy): pro-rate the sign-up week without catch-up`

---

### Task 3: Starter built-ins

**Files:** `priv/repo/migrations/20261010000000_add_starter_workouts.exs`, `lib/burpee_trainer/workouts.ex`; test `test/burpee_trainer/workouts/starter_selection_test.exs`, `test/burpee_trainer/schema_migration_test.exs`

- [x] **Step 1: Build the definitions with the real compiler.** In `T mix run --no-start`, build `WorkoutDefinition.new/1` maps for:
  - "Starter Six-Count": six_count, even, 100 reps, 1200 s, 10 work sets of 10 at `sec_per_rep = sec_per_burpee = 5.0`, 9 rests fitted by `Coach.RestFitter.fit/2` with equal weights;
  - "Starter Navy Seal": navy_seal, even, 40 reps, 1200 s, 8 sets of 5 at 8.0 s, fitted the same way.
  Print `WorkoutDefinition.canonical_map/1`, `ProgramHash.canonical_map/1` and `ProgramHash.hash/1` for each. Paste them as module attributes (literal JSON strings, as `@fallback_definition_json` in `20261005000000_coach_first_schema.exs`).
- [x] **Step 2: Failing tests**
  - migration test (extend `schema_migration_test.exs`): after migrating, exactly one published built-in named "Starter Six-Count" and one "Starter Navy Seal" exist, `verify_stored_draft`-equivalent: recompiling `definition_json` reproduces `program_json` and `content_hash`; "Built-in Steady 10" still exists exactly once.
  - `starter_selection_test.exs`: a user with no completed sessions → `Workouts.ensure_home_selection(scope, slot)` pins the starter whose `burpee_type == slot.burpee_type`; a user with one completed session and no other selection → "Built-in Steady 10" (unchanged).
- [x] **Step 3: Run** — FAIL.
- [x] **Step 4: Implement**
  - Migration `up` inserts both rows with `INSERT ... WHERE NOT EXISTS` on `(user_id IS NULL, name)`; `down` deletes them only if no session or recommendation references them, otherwise raises.
  - `Workouts.built_in_fallback/0` currently takes the lowest-id built-in. Make it select `name = "Built-in Steady 10"` explicitly so the new rows never become the fallback.
  - `initial_home_plan/2`'s fallback branch: `verified_home_fallback(user, slot_burpee_type)` returns the starter for that type when the user has no completed session (`not Repo.exists?(completed session for user)`), else the Steady 10 fallback. Pass the slot's burpee type down from `ensure_home_selection/2` (it receives the slot). This is a data choice between two rows, not a mode: write it as one `starter_or_fallback(user, type)` function with two pattern-matched clauses on the boolean.
- [x] **Step 5: Run** — PASS, then `T mix test`. **Commit** — `feat(workouts): add starter workouts for first use`

**Done** (`feat(workouts): add starter workouts for first use`). Deviations: the migration check lives in `test/burpee_trainer/starter_workouts_migration_test.exs` (the schema test only runs the coach-first migration); `down` is a no-op because `workout_plans_draft_only_delete_trigger` forbids deleting published rows and `up` skips existing starters; at revision 0 the recommendation's Steady 10 placeholder resolves through `starter_or_fallback`, so Home tests for fresh users now expect the starter.

---

### Task 4: First use shows a ready workout

**Files:** `lib/burpee_trainer/home.ex`, `home/state.ex`, `lib/burpee_trainer/workouts.ex`, `lib/burpee_trainer/coach.ex`, `lib/burpee_trainer/coach/plan_next_workout_job.ex`, `lib/burpee_trainer_web/live/{home_live,home_authoring,home_chooser,home_screen,home_workspace}.ex`, `components/home_workout_components.ex`; tests under `test/burpee_trainer/home*`, `test/burpee_trainer_web/live/home_*`.

- [x] **Step 1: Failing tests**
  - `home_test.exs`: a fresh user (no sessions, plans or recommendations) → `Home.facts/2` returns a selection with the starter; `Home.state/1` is `{:start, %{plan: %{name: "Starter Six-Count"}}}` (or Navy Seal per slot type).
  - `state_test.exs`: update the generator (drop `history?`/`owned_plan?`), keep "exactly one primary action" and "started session wins", and add: `primary_action/1` never returns `:describe_first`.
  - LiveView: fresh user `live(conn, ~p"/")` has `[data-home-state=start] [data-primary-action=start]` and no `#home-bootstrap-form`; mounting connected enqueues one `PlanNextWorkoutJob` for the slot; mounting again does not enqueue a second (any state).
- [x] **Step 2: Run** — FAIL.
- [x] **Step 3: Domain**
  - `Home.facts/2`: when the slot needs a workout and no session is started, always call `ensure_selection` (no `history? or owned_plan?` gate). Remove `history?`/`owned_plan?` from `Home.Facts` if `Home.State` no longer reads them.
  - `Home.State`: delete the `:first_workout` clause, its type member and `primary_action(:first_workout)`. `:choose` remains for a genuinely missing selection.
  - `PlanNextWorkoutJob.enqueue_first/1`: same args, inserted with `unique: [period: :infinity, keys: [:user_id, :slot_key], states: :all]` so a slot is planned automatically at most once. Use it from `HomeLive` mount (connected) when `@home_state` is `{:start, %{plan: %{origin: :built_in}}}`; the day-boundary and retry paths keep `enqueue/1`.
- [x] **Step 4: Delete the bootstrap path.** Remove the bootstrap form and alternatives (`HomeWorkoutComponents.bootstrap/1`, its events in `HomeAuthoring`, the `bootstrap?`/`bootstrap_*` assigns in `HomeLive`/`HomeWorkspace`/`HomeChooser`/`HomeScreen`), `Coach.prepare_home_bootstrap/4`, `Coach.confirm_home_bootstrap/3`, `bootstrap_home_draft/4`, and `Workouts.{bootstrap_alternatives/4, select_bootstrap_home_workout/3, start_bootstrap_home_video/4, commit_home_bootstrap/4}` with their private helpers. Then `T mix compile --warnings-as-errors` and delete what the compiler reports unused. Keep `Workouts.home_entry_state/2` only if the `:choose` recovery commands still call it.
- [x] **Step 5: Tests of removed code** — delete `home_bootstrap_test.exs`, `home_bootstrap_lifecycle_test.exs`, `home_entry_state_test.exs` cases that exist only for bootstrap, and bootstrap cases in `home_live_state_test.exs`/`workspace_reentry_test.exs`; rewrite (not delete) any case that also guards ownership or stale state so the guard is still covered through the remaining APIs.
- [x] **Step 6: Run** — `T mix test` → 0 failures. **Commit** — `feat(home): first use opens on a ready starter workout`

**Done** (`feat(home): first use opens on a ready starter workout`). Deviations: `home_entry_state/2` is deleted too: with no bootstrap state, `:choose` only means no workout could be pinned, so recovery no longer requires a returning user (a fresh user in `:choose` may start a video; another user's plan is still refused). `Home.Facts` drops `history?` as well as `owned_plan?` (History computes its own availability). The returning-user mount guards moved to `home_returning_mount_test.exs`, and the inert-without-selection guards became one `:choose` test there.

---

### Task 5: One New form with a Note

**Files:** `lib/burpee_trainer_web/components/home_workout_components.ex` (New form), `lib/burpee_trainer_web/live/home_workout_request.ex`; test in `test/burpee_trainer_web/flows/new_workout_flow_test.exs`

- [x] **Step 1: Failing test** — open New, fill `home_workout[note]` with "slow and steady" alongside the structured fields, submit with a stubbed layout response, and assert the provider request body's messages contain "slow and steady" (read it in the `Req.Test` stub) and the review renders.
- [x] **Step 2: Run** — FAIL (no note input rendered).
- [x] **Step 3: Implement** — render a textarea for `home_workout[note]` labelled "Note", placeholder "Anything the fields don't cover", after "Extended rests", `maxlength="300"` matching `validate_length(:note, max: 300)`. `HomeWorkoutRequest.instruction/1` already sends it.
- [x] **Step 4: Run** — PASS. **Commit** — `feat(home): add a note to the New workout form`

**Done** (`feat(home): add a note to the New workout form`). The test reads the provider request through `TestAuthoringProviderPlug`, which now also records request bodies.

---

### Task 6: Trajectory and last-week metrics

**Files:** `lib/burpee_trainer/insights/metrics.ex`; test `test/burpee_trainer/insights/metrics_test.exs`

- [x] **Step 1: Failing tests** (pure, with fixed dates):
  - an active goal (150 six-count in 1200 s by 2026-12-01) and sessions with best 120 → `goal.<id>.best_reps` 120, `goal.<id>.target_reps` 150, `goal.<id>.days_left` = days from `today` to `date_target` (never negative), plus existing `progress_pct`;
  - `today` = Monday 2026-10-12, previous week 50 minutes, regular week → `last_week.minutes` 50, `last_week.target_minutes` 80; sign-up previous week (Saturday sign-up) → `last_week.target_minutes` 40;
  - property: `last_week.minutes` equals the sum of the previous week's credited durations (div 60).
- [x] **Step 2: Run** — FAIL. **Step 3: Implement** in `compute/5` next to the existing goal and week metrics, using `Week.new(sign_up_date, previous_start)`. **Step 4: Run** — PASS. **Commit** — `feat(insights): goal trajectory and last-week metrics`

**Done** (`feat(insights): goal trajectory and last-week metrics`). Addition: `last_week.*` is omitted when last week precedes the sign-up week (it was never a training week, and "0 of 80" would invite a false shortfall); `days_left` uses a new `:days` unit.

---

### Task 7: Summary validation and storage

**Files:** `lib/burpee_trainer/insights/validator.ex`, `lib/burpee_trainer/coach/summary.ex` (schema + context), migration `20261010000100_create_coach_summaries.exs`; tests `validator_test.exs`, `test/burpee_trainer/coach/summary_test.exs`

- [x] **Step 1: Failing tests**
  - `Validator.validate_summary(%{"text" => t, "metric_ids" => ids}, metrics)`: accepts text whose numbers are the formatted values of cited metrics; rejects an unsupported number, an unknown id, text over 280 characters, more than two sentences (count `.`/`!`/`?` terminators followed by space or end), and empty text.
  - `Summary.store(scope, attrs)` upserts one row per user; `Summary.get(scope)` returns it or `nil`; another user's scope never sees it.
- [x] **Step 2: Run** — FAIL.
- [x] **Step 3: Implement**
  - Extract the existing private number check in `Validator` into one private function used by both `validate/2` and `validate_summary/2`; do not duplicate the regex.
  - Migration: `coach_summaries` (`user_id` references users `on_delete: :delete_all`, unique; `text` text not null; `metric_ids` text JSON not null; `source` string not null; `timestamps(type: :utc_datetime_usec)`).
  - `Coach.Summary` schema + `get/1`, `store/2` (insert with `on_conflict: {:replace, [:text, :metric_ids, :source, :updated_at]}, conflict_target: :user_id`).
- [x] **Step 4: Run** — PASS. **Commit** — `feat(coach): validated summary storage`

**Done** (`feat(coach): validated summary storage`). `numbers_supported/3` was already a single private check, so `validate_summary/2` reuses it with `known/2` and `length_ok/2`; a sentence ends at `.`/`!`/`?` before whitespace or the end, so decimals never split one. `source` is an `Ecto.Enum` (`:llm | :fallback`) and `metric_ids` an `{:array, :string}` stored as JSON text.

---

### Task 8: `SummaryJob` and its triggers

**Files:** `lib/burpee_trainer/coach/summary_job.ex`, `lib/burpee_trainer/workouts.ex` (`admit_completion_jobs/2`), `lib/burpee_trainer/goals.ex` (`confirm/2`, `dismiss/2`), `lib/burpee_trainer_web/live/coach_screen.ex` (notebook save); tests `test/burpee_trainer/coach/summary_job_test.exs`, `completion_admission_test.exs`

- [x] **Step 1: Failing tests** (stub the provider like `narrator_test.exs`):
  - valid `{"text","metric_ids"}` → stored `source: "llm"`, ledger row with `purpose: "summary"`;
  - fabricated number → stored fallback (`source: "fallback"`) whose numbers come from metrics;
  - disabled provider → fallback, no ledger row;
  - no completed session and no active goal → no row stored;
  - admission: completing a session admits `SummaryJob` next to planner and narration (and a failed SummaryJob admission still completes the session, extending the existing admission test's worker list); `Goals.confirm/2` and `Goals.dismiss/2` admit it; a successful notebook save from the Coach screen admits it.
- [x] **Step 2: Run** — FAIL.
- [x] **Step 3: Implement**
  - `SummaryJob`: `use Oban.Worker, queue: :coach, max_attempts: 1, unique: [keys: [:user_id], period: :infinity, states: :incomplete]`. `admit/1` (no own transaction, never rolls back, like `NarrateJob.admit/2`) and `enqueue/1` (own immediate transaction) for callers outside a transaction.
  - `perform/1`: load user → scope; sessions (`Workouts.list_sessions/1`), active goals; `metrics = Metrics.for_scope(...)`; if no session and no active goal, `:ok` without storing. Messages: one system message ("At most two sentences on progress and trajectory toward the active goals, or toward the next level when no goal is active. Cite metric ids for every number. Use only these metrics: <json>"). `Client.chat/2` with `response_format: {"coach_summary", schema}` (`text` maxLength 280, `metric_ids` array of strings), `ledger: %{scope:, purpose: "summary", run_id: Ecto.UUID.generate()}`. Validate with `validate_summary/2`; on anything else store `fallback(metrics)`.
  - `fallback/1` (public, pure, tested): first active goal → "#{target} reps by #{date}: best so far #{best}. #{days} days left." citing the goal ids; no goal → "#{week} of #{target} minutes this week." citing week ids; a short previous week (Task 9) → "Last week: #{m} of #{t} minutes." citing `last_week.*`.
  - Wire `admit/1` into `Workouts.admit_completion_jobs/2` (log as the existing jobs do). `Goals.confirm/2`/`dismiss/2`: admit inside their transaction, log on failure. Coach screen notebook save: call `SummaryJob.enqueue/1` after `Notebook.write/3` succeeds.
- [x] **Step 4: Run** — PASS, then `T mix test`. **Commit** — `feat(coach): generate the progress summary after changes`

**Done** (`feat(coach): generate the progress summary after changes`). Deviations: uniqueness is `states: [:available, :scheduled]` (the spec's wording) rather than `:incomplete`, so a running job never swallows a newer trigger. `summarize/2` is public like `Narrator.narrate/3` so tests pass the stubbed provider. The fallback ranks one-sentence facts (short last week, first goal's trajectory, this week) and keeps two, with every number a metric value ("Best so far 120 of 150 reps with 52 days left.", no date), so it passes `validate_summary/2`. `scripts/e2e/cleanup.exs` deletes the owner's `SummaryJob` rows too. `summary_test.exs` (Task 7) is now `async: false` like every other coach DataCase test: as a concurrent SQLite writer it starved other async tests past the 2 s busy timeout.

---

### Task 9: Refresh the summary on open

Replaces the hourly week-close cron (owner decision): a stale summary is refreshed when the owner opens the app, so inactive owners cost no provider calls.

**Files:** `lib/burpee_trainer/coach/summary.ex` (topic), `lib/burpee_trainer/coach/summary_job.ex` (`on_open/2`, broadcast), `lib/burpee_trainer_web/live/home_live.ex`; tests `summary_job_test.exs`, `test/burpee_trainer_web/live/summary_refresh_test.exs`

- [x] **Step 1: Failing tests**
  - `SummaryJob.on_open(scope, now)`: nothing to report → `{:absent, nil}` and no job; stored summary written in the current local week → `{:current, summary}` and no job; summary written before the current local week, or none with a completed session → `status/2` says `:stale`, and `on_open/2` admits one job and says `{:refreshing, summary_or_nil}` (a failed admission is logged and stays `:stale`, so no loading state waits on a job that does not exist).
  - `perform/1` broadcasts `{:coach_summary, summary_or_nil}` on the owner's topic after summarizing.
  - LiveView: a connected open with a stale summary assigns `progress_summary_loading?: true` and the stored `progress_summary` (named apart from the notebook-derived `coach_summary`, which Task 10 removes); the broadcast clears loading and assigns the new summary; a current summary opens with loading false and admits nothing.
- [x] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS, then `T mix test`. **Commit** — `feat(coach): refresh a stale summary when the app opens`

The loading state itself renders in Task 10's History header (the app's loader, labelled "Updating your summary").

**Done** (`feat(coach): refresh a stale summary when the app opens`).

---

### Task 10: History header and Coach screen

**Files:** `lib/burpee_trainer_web/components/{home_history_components,home_coach_components}.ex`, `lib/burpee_trainer_web/live/{history_screen,coach_screen,home_live}.ex`, `router.ex` unchanged; tests `test/burpee_trainer_web/flows/coach_conversation_flow_test.exs`, a new `test/burpee_trainer_web/flows/history_summary_flow_test.exs`

- [x] **Step 1: Failing tests**
  - History with a stored summary: `#history-header` shows level, `N / target min` for this week, active goals, then `a#history-coach-summary[href="/coach"]` containing the summary text; clicking it patches to `/coach` in the same LiveView process; Coach's back control patches to `/history`.
  - No stored summary (fresh user) → no `#history-coach-summary`, and no other link to `/coach` anywhere on History or Home.
  - `/coach?from=home` behaves exactly like `/coach` (param ignored, back goes to History).
  - Coach screen order: `#coach-summary`, `#coach-goals` (Confirm/Dismiss for proposed), `#coach-message-form` with a `label[for]` "Tell the coach" above a full-width textarea and the submit below, `#coach-reply`, `details#coach-notebook` (closed by default) with Save and Clear inside. Busy state text "Sending to the coach".
- [x] **Step 2: Run** — FAIL.
- [x] **Step 3: Implement** — move the coach entry out of `HomeCoachComponents.entry/1` into the History header as the summary link; delete the `from` handling (`?from=history|home`) from `CoachScreen`/`HomeLive` so back always patches to `/history`; restructure `HomeCoachComponents.panel/1` in the order above (keep element ids that existing ownership/flow tests use where the element survives: `#home-coach-notebook-form`, `#home-coach-message-form`). Load `Summary.get/1` in the History and Coach screen loaders.
- [x] **Step 4: Run** — `T mix test test/burpee_trainer_web` → PASS. **Commit** — `feat(history): coach summary heads History and opens Coach`

**Done** (`feat(history): coach summary heads History and opens Coach`). Deviations: Coach element ids keep their `home-coach-` prefix (`#home-coach-summary`, `#home-coach-goals`, `#home-coach-reply`, `#home-coach-notebook`) so surviving elements keep the ids existing tests use. The summary line shows whenever there is a summary or one is loading (the loader sits inside the link, labelled "Updating your summary"). Tests that only exercise Coach behaviour patch to `/coach` directly, since a summary (and so the link) needs something to report; the entry itself is covered by `history_summary_flow_test.exs`. Three `coach_workspace_test` cases that asserted `?from=` referrers and Home's coach entry were superseded and removed. New classes (`history-header*`, `history-coach-summary`, `coach-summary-*`, `coach-message-form`) get their styling in Task 11.

---

### Task 11: One visual system

**Files:** `assets/css/adaptive_home.css`, `assets/css/app.css`, `lib/burpee_trainer_web/components/home_workout_components.ex` (chooser heading), session panel styles in `app.css` (`#burpee-session` idle/review panels only; runner timing colours untouched)

- [x] **Step 1: Inventory** — `grep -n "background\|font" assets/css/adaptive_home.css assets/css/app.css` and list every hard-coded page background (`#F3EEE8`, `#f6f4ef`, `#e7e8e5`, `#fbfaf8`) and every non-Geist font declaration (`Arial`, `Georgia`, `Helvetica`).
- [x] **Step 2: Replace** — page backgrounds (`html`, `body`, `.session-surface:has(> #home-page …)`, `#home-page`, History, Coach, `#burpee-session` idle panels) use `var(--color-base-100)`; sheets/chooser use `var(--color-base-200)`; font declarations use `var(--font-sans)`. Headline sizes keep their current scale; only the family changes. The chooser `h2` and `.home-history-sheet h2` use the shared screen-heading rule. History and Coach use Home's column (`width: min(580px, 100%)`, centred) and the shared `.home-state-heading` scale.
- [x] **Step 3: Verify** — `grep -n "Georgia\|Arial\|Helvetica\|#F3EEE8\|#f6f4ef\|#e7e8e5\|#fbfaf8" assets/css` prints nothing (dark-theme tokens are out of scope and stay); `T mix assets.build` exits 0; `npm --prefix assets test` passes.
- [x] **Step 4: Browser check (owner's signed-in Chrome, no sign-in by the agent)** — screenshot Home, New, chooser, History, Coach and a session pre-start at 720 px and 400 px wide; the page background and typeface are identical on all six; save the screenshots for the report.
- [x] **Step 5: Commit** — `style: one background, one typeface, one column`

**Done** (`style: one background, one typeface, one column`). Findings beyond the CSS: History and Coach were rendered outside `.adaptive-home` and in a different layout wrapper (`max-w-2xl` with its own padding) because `Layouts.session_surface_page?/1` covered only Home; both now render inside `.adaptive-home` and are session-surface pages, so all three share Home's surface, gutters and 640 px column. About 40 rules for removed elements (first-use form, old coach entry and guidance row) were deleted. The verification grep leaves only the `--font-sans` token's system fallbacks and the dark-theme count-in `--session-active-bg` (out of scope). Browser check: Home, History, Coach, New and the chooser at 720 px and ~350 px (same-origin iframes; the window could not be resized because it sat off-screen); the session pre-start was not captured because reaching it starts a workout.

---

### Task 12: Docs

**Files:** `docs/ui.md`, `CLAUDE.md`, `docs/testing.md`

- [ ] `docs/ui.md`: the navigation-bar section was already replaced by "Navigation and screens" in the docs restructure; check it still matches the shipped Home, History and Coach, and document the page background and Geist-only rule there.
- [ ] `CLAUDE.md` module map: add `Coach.Policy.Week`, `Coach.Summary`, `Coach.SummaryJob`, `Coach.WeekCloseJob`; remove anything Task 4 deleted.
- [ ] `docs/testing.md`: add the history summary flow and the first-use start flow to the core flow list.
- [ ] **Commit** — `docs: frictionless Home, summary and visual rules`

---

### Task 13: Verification

- [ ] `T mix precommit 2>&1 | tail -5` — 0 failures, no warnings.
- [ ] `npm --prefix assets test` — 0 failures; `T mix assets.build` — exit 0.
- [ ] Manual walkthrough in the owner's browser (owner signs in; the agent never enters credentials): fresh-user Home shows a starter with Start; New shows the Note; History shows the summary after one completed session; tapping it opens Coach; Coach's back returns to History; backgrounds and fonts match on every screen.
- [ ] Report: commits, removed modules and tests, new tables and jobs, screenshots, test counts, and confirmation that no paid calls were made.
