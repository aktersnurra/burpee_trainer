# BurpeeTrainer — Full Project Specification

> Read this file thoroughly before doing anything.
> Generate a plan and wait for my approval before writing any code.

---

## NAMING CONVENTIONS

Follow TigerStyle naming principles throughout the codebase:

- **Units and qualifiers go last, sorted by descending significance.** The most significant word
  comes first, units and qualifiers trail. This ensures related variables group and align naturally.
  Examples: `duration_sec_planned`, `duration_sec_actual`, `rest_sec_warmup`, `burpee_count_target`.
- **No abbreviations.** Write `duration_sec` not `dur_sec`, `burpee_count` not `rep_count`,
  `position` not `pos`. Exception: conventional loop indices.
- **Equal-length related names.** When two variables are paired, prefer names of equal character
  count so they line up in code. Example: `note_pre` / `note_post`.
- **Infuse names with meaning.** A name should tell you what the thing *is* and *why it exists*,
  not just its type. `rest_sec_shave_accumulated` is better than `extra_rest`.
- **State invariants positively.** Name booleans in their true form: `warmup_enabled` not
  `skip_warmup`.
- **Callback and helper functions** are prefixed with the calling function name:
  `build_timeline/1` and `build_timeline_warmup/1`.

---

## AUTH

- Single user. Seed via `mix burpee_trainer.create_user` (prompts for username + password).
- bcrypt password hashing, session cookie auth.
- All data scoped to `user_id` — schema is multi-user capable even though only one user exists.

---

## DATA MODEL

Field names follow the conventions above: units suffixed (`_sec`, `_count`), qualifiers trailing
(`_planned`, `_actual`, `_target`, `_baseline`).

### User
```
id
username
password_hash
```

### WorkoutPlan
```
id
user_id
name
burpee_type                   -- enum: six_count | navy_seal
warmup_enabled                -- bool (true means warmup is active)
warmup_reps                   -- int, manually set
warmup_rounds                 -- int, manually set
rest_sec_warmup_between       -- int, default 120
rest_sec_warmup_before_main   -- int, default 180
shave_off_sec                 -- int, nullable
shave_off_block_count         -- int, nullable
video_id                      -- nullable foreign key -> WorkoutVideos
has_many blocks (ordered by position)
```

### Block
```
id
plan_id
position                      -- int (ordering, 1-based)
repeat_count                  -- int, default 1
has_many sets (ordered by position)
```

> **No separate inter-block rest field.** The last set's `rest_sec_after_set` serves as the gap
> before the next block. This is not a coincidence — it is the design. Document in code comments.

### Set
```
id
block_id
position                      -- int (ordering, 1-based)
burpee_count                  -- int
sec_per_burpee                -- float
rest_sec_after_set            -- int, default 0
```

### WorkoutSession
```
id
user_id
plan_id                       -- nullable
burpee_type                   -- enum: six_count | navy_seal
burpee_count_planned          -- int
duration_sec_planned          -- int
burpee_count_actual           -- int
duration_sec_actual           -- int
note_pre                      -- text, nullable
note_post                     -- text, nullable
tags                          -- stored as comma-separated string in SQLite
                              -- values: tired | great_energy | bad_sleep | sick | travel | hot

-- Derived fields (computed and stored at save time, never recomputed):
rate_per_min_actual           -- float: burpee_count_actual / duration_sec_actual * 60
days_since_last               -- int: days since previous session of same burpee_type (null if first)
rate_delta                    -- float: rate_per_min_actual minus previous session rate (null if first)
rate_avg_rolling_3            -- float: EMA of last 3 sessions rate_per_min_actual, same burpee_type
time_of_day_bucket            -- atom, derived from local hour of inserted_at:
                              --   :morning   06:00-11:59
                              --   :afternoon 12:00-16:59
                              --   :evening   17:00-20:59
                              --   :night     21:00-05:59
style_name                    -- atom, nullable: archetype used
mood                          -- int: -1 | 0 | 1

inserted_at                   -- full timestamp, time preserved
```

> Compute all derived fields in `Workouts.save_session/2` before inserting. Store them —
> never recompute at read time.

### Goal
```
id
user_id
burpee_type                   -- enum: six_count | navy_seal (one active per type max)
burpee_count_target           -- int
duration_sec_target           -- int
date_target                   -- date
burpee_count_baseline         -- int
duration_sec_baseline         -- int
date_baseline                 -- date
status                        -- enum: active | achieved | abandoned
inserted_at
```

### StylePerformance
```
id
user_id
style_name                    -- atom: long_sets | burst | pyramid | ladder_up | even |
                              --       even_spaced | front_loaded | descending | minute_on
burpee_type                   -- enum: six_count | navy_seal
mood                          -- int: -1 | 0 | 1
level                         -- atom: level_1a .. level_4 | graduated
time_of_day_bucket            -- atom: :morning | :afternoon | :evening | :night
session_count                 -- int
completion_ratio_sum          -- float
rate_sum                      -- float
```

> Context bucket: `(user_id, style_name, burpee_type, mood, level, time_of_day_bucket)`.
> Upserted after each session save.

### WorkoutVideo
```
id
name                          -- e.g. "Day 1 - Level 1A 6-count"
filename                      -- e.g. "bdp_day1_6count.mp4"
burpee_type                   -- enum: six_count | navy_seal
duration_sec                  -- int (informational)
inserted_at
```

---

## LEVELS MODULE

Pure Elixir module `BurpeeTrainer.Levels`. No Ecto dependency.

### Landmark table (hardcoded)
```elixir
@landmarks [
  %{level: :graduated, six_count: 325, navy_seal: 150},
  %{level: :level_4,   six_count: 275, navy_seal: 120},
  %{level: :level_3,   six_count: 250, navy_seal: 100},
  %{level: :level_2,   six_count: 200, navy_seal:  80},
  %{level: :level_1d,  six_count: 150, navy_seal:  60},
  %{level: :level_1c,  six_count: 100, navy_seal:  40},
  %{level: :level_1b,  six_count:  50, navy_seal:  20},
  %{level: :level_1a,  six_count:   1, navy_seal:   1},
]
```

Qualifies when: `duration_sec_actual <= 1200` AND `burpee_count_actual >= threshold`.
Level is derived from sessions, never stored.

### Public API
```elixir
BurpeeTrainer.Levels.current_level/1
# [%WorkoutSession{}] -> level_atom  (lower of the two per-type levels)

BurpeeTrainer.Levels.level_for_type/2
# [%WorkoutSession{}], burpee_type -> level_atom

BurpeeTrainer.Levels.next_landmark/2
# [%WorkoutSession{}], burpee_type -> %{level: atom, burpee_count_required: int}

BurpeeTrainer.Levels.landmark_achieved?/3
# [%WorkoutSession{}], burpee_type, level -> boolean

BurpeeTrainer.Levels.landmark_history/1
# [%WorkoutSession{}] -> [%{level, burpee_type, session_id, date_unlocked}]
```

### Tests (ExUnit)
Cover: landmark qualification, overall level = min of two types, next_landmark threshold,
graduated state, zero sessions.

---

## PLAN WIZARD MODULE

Pure Elixir module `BurpeeTrainer.PlanWizard`. No Ecto dependency.
Converts simple high-level inputs into a fully structured `%WorkoutPlan{}`.

### Input struct
```elixir
%WizardInput{
  duration_sec_total,     -- int: total workout time e.g. 1200
  burpee_type,            -- atom: :six_count | :navy_seal
  burpee_count_total,     -- int: total reps e.g. 120
  sec_per_burpee,         -- float: time per rep e.g. 5.0
  pacing_style,           -- atom: :even | :unbroken
  extra_rest,             -- nullable: %{after_block: int, rest_sec: int}
}
```

### Generation logic

```
work_sec_total = burpee_count_total * sec_per_burpee
rest_sec_total = duration_sec_total - work_sec_total

:even ->
  Distribute reps into equal sets with consistent rest between each.
  Produces one block, repeat_count = set_count, one set per repetition.

:unbroken ->
  unbroken reps into groups with micro-rest (3-5s) inside groups,
  longer rest between groups.
  set_size: six_count -> 8-15 reps, navy_seal -> 3-5 reps.
  Produces one block with multiple sets.

extra_rest ->
  Split into two blocks at after_block boundary.
  Last set of block N gets rest_sec_after_set = extra_rest.rest_sec.
  Remaining rest budget redistributed across other sets.
```

Output is `%WorkoutPlan{}` with all blocks/sets populated, unsaved, ready for editor review.

### Public API
```elixir
BurpeeTrainer.PlanWizard.generate/1
# %WizardInput{} -> {:ok, %WorkoutPlan{}} | {:error, reason}

BurpeeTrainer.PlanWizard.validate/1
# %WizardInput{} -> :ok | {:error, [reason]}
```

### Tests (ExUnit)
Cover: even pacing totals, unbroken pacing, extra rest block split,
work time exceeding total duration returns error, zero burpees returns error.

---

## PLANNER MODULE

Pure Elixir module `BurpeeTrainer.Planner`. No Ecto dependency.

### Event struct
```elixir
%Event{
  type:         :warmup_burpee | :warmup_rest | :work_burpee | :work_rest | :shave_rest,
  duration_sec: float,
  burpee_count: integer | nil,
  label:        string
}
```

### Timeline logic

1. **Warmup** (if `warmup_enabled`): emit rounds, inter-round rest, pre-main rest.
2. **Main**: expand each block by `repeat_count`, emit sets as work+rest pairs.
3. **Shave-off**: after blocks 1..N, inject `:shave_rest` of `shave_off_sec * repetitions`.

### Public API
```elixir
BurpeeTrainer.Planner.to_timeline/1   # %WorkoutPlan{} -> [%Event{}]
BurpeeTrainer.Planner.summary/1       # %WorkoutPlan{} -> %{burpee_count_total, duration_sec_total, blocks: [...]}
```

Helpers: `build_timeline/1`, `build_timeline_warmup/1`, `build_timeline_block/2`,
`build_timeline_shave_rest/2`.

### Tests (ExUnit)
Cover: plan expansion, shave-off accumulation, warmup generation, zero-rest edge cases,
repeat_count > 1, empty block list.

---

## PROGRESSION MODULE

Pure Elixir module `BurpeeTrainer.Progression`. No Ecto dependency.

### Periodization (3 weeks build + 1 deload)
```elixir
phase = case rem(weeks_elapsed, 4) do
  1 -> :build_1   # 0.90
  2 -> :build_2   # 1.00
  3 -> :build_3   # 1.05
  0 -> :deload    # 0.80
end
burpee_count_suggested = round(burpee_count_target_linear * phase_multiplier)
```

### Trend status
- `:ahead` | `:on_track` — projected on target
- `:behind` — projected < target by > 10%; boost multiplier +0.05
- `:low_consistency` — fewer than 2 sessions in last 14 days
- `:plateau` — last 4 `rate_delta` within ±3%

### Public API
```elixir
BurpeeTrainer.Progression.recommend/2   # %Goal{} | :implicit, [%WorkoutSession{}] -> %Recommendation{}
BurpeeTrainer.Progression.project_trend/1  # [%WorkoutSession{}] -> [{date, burpee_count_projected}]
```

### Tests (ExUnit)
Cover: on-track, behind, deload, plateau, < 4 sessions, zero sessions, implicit goal.

---

## STYLE RECOMMENDER

### Archetypes

6-count: `long_sets` (1C+), `burst` (any), `pyramid` (1B+), `ladder_up` (1B+), `even` (any)
Navy seal: `even_spaced` (any), `front_loaded` (1B+), `descending` (1C+), `minute_on` (1D+)

### BurpeeTrainer.StyleGenerator
```elixir
BurpeeTrainer.StyleGenerator.generate/2
# style_name, %Recommendation{} -> %WorkoutPlan{}
```

### BurpeeTrainer.StyleRecommender
```elixir
BurpeeTrainer.StyleRecommender.recommend/1
# %{burpee_type, mood, level, time_of_day_bucket, sessions, performances, progression_rec}
# -> [%StyleSuggestion{}, ...] (top 3)
```

### Bayesian scoring
```elixir
@prior_weight 3
@prior_mean   0.85
score = (@prior_weight * @prior_mean + session_count * avg_completion) /
          (@prior_weight + session_count)
```

### Modifiers (hardcoded starting priors — overridden by data within ~5 sessions)

Mood:
```
-1: burst +0.10, even +0.05, long_sets -0.10, descending -0.10
+1: long_sets +0.10, pyramid +0.05, descending +0.05, burst -0.05
```

Time of day:
```
evening: burst +0.05, long_sets -0.05, descending -0.05
night:   burst +0.10, long_sets -0.10, descending -0.10, even +0.05
```

Plateau override: unused styles (last 3 sessions) get +0.15.

### StyleSuggestion struct
```elixir
%StyleSuggestion{style_name, score, session_count, plan, rationale}
```

### Upgrade path
Contextual bandit documented as comment in `style_recommender.ex`.
Context = `(mood, level, time_of_day_bucket)`, arms = archetypes, reward = completion_ratio.

### Tests (ExUnit)
Cover: score convergence, prior at zero sessions, level filter, plateau override,
mood/time modifiers, top 3 returned.

---

## LIVE SESSION

### State machine
```
idle -> warmup_burpee -> warmup_rest -> work_burpee -> work_rest -> shave_rest -> done
```

### Display
Phase label, burpees remaining in set, countdown, overall progress bar, pause button.

### JS Hooks

`BurpeeHook` — Web Audio API:
- Rep beep: 880hz, 80ms, square. Client metronome at `sec_per_burpee * 1000` ms.
- Rest-ending beep: 440hz, 400ms, sine. Server push when 5s remain in rest.

`VideoHook` — HTML5 video sync:
- Receives `push_event`: `"video_play"` / `"video_pause"`.
- Pause button triggers both `"pause_metronome"` and `"video_pause"`.
- Resume triggers both `"start_metronome"` and `"video_play"`.
- Video panel: collapsible, collapsed by default on mobile. Toggle: "Show / Hide video".
- src="/videos/#{filename}" — routed through VideoController for auth.

### Mood input
Tap-to-start overlay: 😮‍💨 Tired (-1) / 😐 OK (0) / 💪 Hyped (+1).
Initializes AudioContext on tap (browser requirement).

### Completion modal
Pre-filled, all editable: `burpee_count_actual`, `duration_sec_actual`, `mood`,
`tags` (multi-select), `note_pre`, `note_post`.
On save: `Workouts.save_session/2` computes all derived fields, upserts `StylePerformance`.

---

## PLANS PAGE — `/plans`

Two entry points into plan creation:

```
[ Quick Generate ]   [ Build Manual ]

Saved Plans
[ Plan ] [ Plan ] [ Plan ] ...
```

### Quick generator wizard (primary path)

Six steps, one per screen, forward/back navigation:

```
Step 1  Total time        slider/input, default 20 min, range 5-60 min
Step 2  Burpee type       two large tap targets: [6-Count] [Navy Seal]
Step 3  Total burpees     number input. Live hint: "X burpees/min".
                          Warn if work_sec > duration_sec.
Step 4  Sec per burpee    +/- buttons, default 5s. Live: "Work Xm Ys · Rest Xm Ys"
Step 5  Pacing style      [Even pacing] [unbroken sets]
Step 6  Extra rest?       toggle off by default. If on: "After block _ , rest _ sec"
```

Generate -> `PlanWizard.generate/1` -> opens full editor pre-populated.
Validation error -> inline message, stay on relevant step.

### Full plan editor (advanced / post-wizard review)

- Header: name, burpee_type, video selector (filtered by type, nullable).
- Warmup (collapsible): `warmup_reps`, `warmup_rounds`, `rest_sec_warmup_between`,
  `rest_sec_warmup_before_main`.
- Shave-off (collapsible): `shave_off_sec`, `shave_off_block_count`, live summary text.
- Block builder: add/remove/reorder, repeat_count, sets with burpee_count/sec_per_burpee/
  rest_sec_after_set.
- Live summary sidebar via `Planner.summary/1`.
- Save button.

---

## HISTORY PAGE — `/history`

Chart: x=date, y=`burpee_count_actual`, series per type (blue/orange).
Dots shaped by `time_of_day_bucket`: morning=filled circle, afternoon=filled square,
evening=open circle, night=open square.
Overlays: goal line, trend line (dotted), landmark reference lines.

PR panel: best burpees, longest session, best rate, best rate by time-of-day bucket.

Session table: date, time-of-day badge, type badge, burpees, duration, mood, tags, notes.

---

## GOALS PAGE — `/goals`

Level display:
```
Current Level: 1C
6-counts   1C unlocked  next: 150 for 1D
Navy Seals 1B unlocked  next:  40 for 1C  <- bottleneck in amber
```

Goal card: target summary, three-point progress bar, phase + trend badges.
Implicit goal from next landmark if no explicit goal set.

Recommendation panel:
- "Get style recommendation" -> mood picker -> time auto-detected -> top 3 cards
  -> "Use this" (editor) or "Run directly" (session).
- "Build plan manually" -> wizard pre-filled with suggestion.
- "Log free session".

---

## FREE-FORM LOGGING — `/log`

Fields: `burpee_type`, `burpee_count_actual`, `duration_sec_actual`,
`mood`, `tags`, `note_pre`, `note_post`, `inserted_at` (default now, editable).
On save: same derived field computation as completion modal.

---

## VIDEO STREAMING

Files at `/var/lib/burpee_trainer/videos/`. Managed manually via mix task.

### Auth — X-Accel-Redirect
```elixir
# VideoController
def stream(conn, %{"filename" => filename}) do
  if conn.assigns.current_user do
    conn
    |> put_resp_header("x-accel-redirect", "/protected-videos/#{filename}")
    |> put_resp_header("content-type", "video/mp4")
    |> send_resp(200, "")
  else
    redirect(conn, to: ~p"/login")
  end
end
```

### Nginx
```nginx
location /videos/ {
    proxy_pass http://localhost:4000;
}

location /protected-videos/ {
    internal;
    alias /var/lib/burpee_trainer/videos/;
    mp4;
    mp4_buffer_size     1m;
    mp4_max_buffer_size 5m;
    add_header Accept-Ranges bytes;
}
```

---

## PROJECT STRUCTURE

```
lib/
  burpee_trainer/
    accounts.ex            # User auth context
    workouts.ex            # Plans, blocks, sets, sessions, style_performances
    goals.ex               # Goals CRUD
    videos.ex              # WorkoutVideo CRUD
    levels.ex              # Pure: level derivation
    plan_wizard.ex         # Pure: WizardInput -> WorkoutPlan
    planner.ex             # Pure: plan -> timeline + summary
    progression.ex         # Pure: goal + sessions -> recommendation
    style_recommender.ex   # Pure: context -> top 3 StyleSuggestion
    style_generator.ex     # Pure: archetype + recommendation -> WorkoutPlan
  burpee_trainer_web/
    controllers/
      video_controller.ex  # X-Accel-Redirect auth
    live/
      session_live.ex
      planner_live.ex      # wizard + full editor
      history_live.ex
      goals_live.ex
      log_live.ex
    components/
priv/
  repo/migrations/
assets/
  js/
    hooks/
      burpee_hook.js
      chart_hook.js
      video_hook.js
```

---

## MIX TASKS

```
mix burpee_trainer.create_user
mix burpee_trainer.add_video NAME FILENAME BURPEE_TYPE
```

---

## DEPLOYMENT

- nginx: `burpee.gustafrydholm.xyz` -> `localhost:4000`
- TLS: certbot
- Process: systemd
- Release: `mix release`
- SQLite: `/var/lib/burpee_trainer/db.sqlite3` via `DATABASE_PATH` env var
- Videos: `/var/lib/burpee_trainer/videos/`

```bash
#!/usr/bin/env bash
set -euo pipefail
APP=burpee_trainer
HOST=burpee.gustafrydholm.xyz
DEPLOY_PATH=/opt/$APP
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
rsync -avz --delete _build/prod/rel/$APP/ $HOST:$DEPLOY_PATH/
ssh $HOST "systemctl restart $APP"
```

---

## FUTURE FEATURES

- **Chat-based plan generation**: natural language -> OpenRouter LLM -> structured intent
  -> `StyleGenerator` -> plan editor. One module `BurpeeTrainer.ChatPlanner`.
  Build after core app is stable with real session data.

---

## CONSTRAINTS & PREFERENCES

- SQLite via `ecto_sqlite3`. No Postgres.
- Raw SQL via `Ecto.Adapters.SQL.query!/3` for all queries. No `Ecto.Schema`, no
  `Ecto.Changeset`. Ecto for connection pooling, migrations, transactions only.
- No JavaScript frameworks. Tailwind + LiveView + minimal vanilla JS hooks only.
- Web Audio API for audio. No audio files, no external libs.
- Chart.js via CDN.
- All `BurpeeTrainer.*` modules: pure functional, no Ecto, no side effects, unit-testable.
- ExUnit tests for: `Levels`, `PlanWizard`, `Planner`, `Progression`,
  `StyleRecommender`, `StyleGenerator`.
- Plain `GenServer`/`Process` for concurrency. No third-party concurrency libs.
- No VS Code config files.
- TigerStyle naming: units and qualifiers trail, no abbreviations,
  helpers prefixed with calling function name.
