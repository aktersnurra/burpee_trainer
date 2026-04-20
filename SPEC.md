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
  count so they line up in code. Example: `note_pre` / `note_post` over `pre_note` / `post_note`.
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
rest_sec_warmup_between       -- int, default 120  (rest between warmup rounds)
rest_sec_warmup_before_main   -- int, default 180  (rest after last warmup round, before main workout)
shave_off_sec                 -- int, nullable (seconds saved per block repetition)
shave_off_block_count         -- int, nullable (accumulate savings from blocks 1..N, inject before block N+1)
has_many blocks (ordered by position)
```

### Block
```
id
plan_id
position                      -- int (ordering, 1-based)
repeat_count                  -- int, default 1 ("execute this block N times")
has_many sets (ordered by position)
```

> **No separate inter-block rest field.** The last set's `rest_sec_after_set` serves as the gap
> before the next block. This is not a coincidence — it is the design. Document this in code comments.

### Set
```
id
block_id
position                      -- int (ordering, 1-based)
burpee_count                  -- int
sec_per_burpee                -- float (time to complete one rep)
rest_sec_after_set            -- int, default 0 (0 on the last set of the last block)
```

### WorkoutSession
```
id
user_id
plan_id                       -- nullable (free-form sessions have no plan)
burpee_type                   -- enum: six_count | navy_seal
burpee_count_planned          -- int
duration_sec_planned          -- int
burpee_count_actual           -- int
duration_sec_actual           -- int
note_pre                      -- text, nullable
note_post                     -- text, nullable
inserted_at                   -- used as the session date
```

### Goal
```
id
user_id
burpee_type                   -- enum: six_count | navy_seal (one active goal per type max)
burpee_count_target           -- int (e.g. 200)
duration_sec_target           -- int (e.g. 1200 = 20 min)
date_target                   -- date
burpee_count_baseline         -- int (from benchmark session)
duration_sec_baseline         -- int
date_baseline                 -- date
status                        -- enum: active | achieved | abandoned
inserted_at
```

---

## PLANNER MODULE

Pure Elixir module `BurpeeTrainer.Planner`. No Ecto dependency. Takes a `%WorkoutPlan{}` struct
(with preloaded blocks and sets) and produces a flat ordered list of timed events — the **timeline**.

### Event struct
```elixir
%Event{
  type:          :warmup_burpee | :warmup_rest | :work_burpee | :work_rest | :shave_rest,
  duration_sec:  float,
  burpee_count:  integer | nil,
  label:         string        # e.g. "Block 2 · Set 1", "Warmup Round 1", "Shave-off Rest"
}
```

### Timeline logic

1. **Warmup** (if `warmup_enabled`):
   - Emit `warmup_rounds` rounds of (`warmup_reps` burpees at first block's first set pace).
   - Between rounds: `:warmup_rest` of `rest_sec_warmup_between`.
   - After final warmup round: `:warmup_rest` of `rest_sec_warmup_before_main`.

2. **Main workout**:
   - Expand each block by `repeat_count`. For each repetition emit its sets in order.
   - Each set emits `:work_burpee` (duration = `burpee_count * sec_per_burpee`) then `:work_rest`
     (duration = `rest_sec_after_set`), skipping rest if 0.

3. **Shave-off rest**:
   - After all repetitions of blocks 1..`shave_off_block_count` are emitted, inject one `:shave_rest` event.
   - Duration = `shave_off_sec * total_repetitions_in_blocks_1_to_N`.
   - Then continue with block `shave_off_block_count + 1`.

### Public API
```elixir
BurpeeTrainer.Planner.to_timeline/1
# %WorkoutPlan{} -> [%Event{}]

BurpeeTrainer.Planner.summary/1
# %WorkoutPlan{} -> %{burpee_count_total, duration_sec_total, blocks: [...]}
```

Helper functions follow the calling-function prefix convention:
```elixir
build_timeline/1
build_timeline_warmup/1
build_timeline_block/2
build_timeline_shave_rest/2
```

### Example mapping (navy seal plan)
```
Block(repeat_count=3): [ Set(burpee_count=4, sec_per_burpee=4.0, rest_sec_after_set=36) ]
Block(repeat_count=1): [ Set(burpee_count=3, sec_per_burpee=4.0, rest_sec_after_set=0)  ]
shave_off_sec=8, shave_off_block_count=1
→ after 3 repetitions of block 1: inject shave_rest of 8×3=24s before block 2
```

### Tests (ExUnit)
Cover: basic plan expansion, shave-off accumulation, warmup generation, zero-rest edge cases,
`repeat_count` > 1, empty block list.

---

## PROGRESSION MODULE

Pure Elixir module `BurpeeTrainer.Progression`. No Ecto dependency. Takes a `%Goal{}` and a list
of recent `%WorkoutSession{}` structs, returns a `%Recommendation{}`.

### Periodization logic (3 weeks build + 1 week deload)

```elixir
weeks_total   = ceil((date_target   - date_baseline) / 7)
weeks_elapsed = ceil((date_today    - date_baseline) / 7)

# Linear interpolation toward goal
burpee_count_target_linear =
  burpee_count_baseline +
  (burpee_count_target - burpee_count_baseline) * (weeks_elapsed / weeks_total)

phase = case rem(weeks_elapsed, 4) do
  1 -> :build_1   # multiplier 0.90
  2 -> :build_2   # multiplier 1.00
  3 -> :build_3   # multiplier 1.05
  0 -> :deload    # multiplier 0.80
end

burpee_count_suggested = round(burpee_count_target_linear * phase_multiplier)
```

### Trend monitoring

From the last 4 sessions of matching `burpee_type`, fit a linear trend using least squares
(implement in pure Elixir — arithmetic on lists only). Project reps at `date_target`:

- Projected >= target → `:on_track` or `:ahead`
- Projected < target by > 10% → `:behind`; boost next week's multiplier by +0.05
- Fewer than 2 sessions in last 14 days → `:low_consistency`

### Recommendation struct
```elixir
%Recommendation{
  goal_id,
  burpee_type,
  phase,                              # :build_1 | :build_2 | :build_3 | :deload
  trend_status,                       # :ahead | :on_track | :behind | :low_consistency
  burpee_count_suggested,
  duration_sec_suggested,
  sec_per_burpee_suggested,           # derived: duration_sec_suggested / burpee_count_suggested
  rationale,                          # e.g. "Build week 2 · on track · target 165 reps in 20 min"
  weeks_remaining,
  burpee_count_projected_at_goal      # from trend line projected at date_target
}
```

### Public API
```elixir
BurpeeTrainer.Progression.recommend/2
# %Goal{}, [%WorkoutSession{}] -> %Recommendation{}

BurpeeTrainer.Progression.project_trend/1
# [%WorkoutSession{}] -> [{date, burpee_count_projected}]
```

### Tests (ExUnit)
Cover: on-track projection, behind adjustment (+0.05 boost), deload week calculation,
fewer-than-4-sessions edge case, zero sessions edge case.

---

## LIVE SESSION

### State machine
```
idle → warmup_burpee → warmup_rest → work_burpee → work_rest → shave_rest → done
```

The LiveView process drives state transitions via `:timer.send_interval`. The timeline from
`Planner.to_timeline/1` is computed on mount and used as the source of truth for all transitions.

### Display
- Phase label: e.g. "Block 2 · Set 1 · Rep 4/8" or "Warmup Round 1" or "Shave-off Rest"
- Burpees remaining in current set
- Time remaining in current phase (countdown, in seconds)
- Overall progress bar: `duration_sec_elapsed / duration_sec_total`
- Pause button — freezes server timer, sends `"pause_metronome"` push_event to JS hook

### Audio (JS Hook: `BurpeeHook`)
Web Audio API only — no audio files, no external dependencies.
- **Rep beep**: short tone. Client-side metronome (`setInterval` at `sec_per_burpee * 1000` ms).
  Started/stopped by `push_event` from LiveView on phase transitions.
- **Rest-ending beep**: distinct longer tone. Triggered by `push_event` from server when
  `rest_sec_warning = 5` seconds remain in any rest phase.

### Completion modal
Triggered when state machine reaches `:done`. Fields pre-filled from plan, all editable:
- `burpee_count_actual` (pre-filled: `burpee_count_planned`)
- `duration_sec_actual`  (pre-filled: `duration_sec_planned`)
- `note_pre`  (text, optional)
- `note_post` (text, optional)

Saving creates a `%WorkoutSession{}` record. Cancelling discards without saving (confirm dialog).

---

## PLANNER UI — `/plans`

### Plan list
- Grid of saved plans showing: name, burpee_type, `burpee_count_total`, `duration_sec_total`
  (from `Planner.summary/1`).
- Actions: new, edit, delete, duplicate.

### Plan editor
- **Header**: name field, burpee_type selector (six_count | navy_seal).
- **Warmup section** (collapsible, toggled by `warmup_enabled`):
  - `warmup_reps`, `warmup_rounds`, `rest_sec_warmup_between`, `rest_sec_warmup_before_main`
- **Shave-off panel** (collapsible):
  - `shave_off_sec`, `shave_off_block_count`
  - Live-computed summary: *"Saving 8s × 3 repetitions = 24s extra rest before block 2"*
- **Block builder**:
  - Add / remove / reorder blocks (up/down buttons)
  - Each block: `repeat_count` field + set list
  - Each set: `burpee_count`, `sec_per_burpee`, `rest_sec_after_set` + add/remove set buttons
- **Live summary sidebar** (recomputed on every change via `Planner.summary/1`):
  - `burpee_count_total`, `duration_sec_total`
  - Per-block breakdown: "Block 1 (×3): 4 reps × 3 sets = 12 burpees, ~52s work + 36s rest"
- Save button.

---

## HISTORY PAGE — `/history`

### Chart
Chart.js via CDN, driven by a LiveView JS hook (`ChartHook`).
- X-axis: session date (`inserted_at`)
- Y-axis: `burpee_count_actual`
- One series per `burpee_type`: six_count = blue, navy_seal = orange
- If an active goal exists for a type, overlay two dotted lines at reduced opacity:
  1. **Goal line**: `date_baseline / burpee_count_baseline` → `date_target / burpee_count_target`
  2. **Trend line**: from `Progression.project_trend/1`

### PR panel
Per `burpee_type`:
- Most burpees in a single session (`burpee_count_actual` max)
- Longest session (`duration_sec_actual` max)
- Best rate: `burpee_count_actual / duration_sec_actual * 60` (burpees per minute)

### Session table
Sortable by date, type, burpees, duration. Columns: date, type badge, `burpee_count_actual`,
`duration_sec_actual`, notes preview (truncated). Click row to expand `note_pre` / `note_post`.

---

## GOALS PAGE — `/goals`

Per `burpee_type`: show active goal card or "Set a goal" prompt.

### Goal card
- Target summary: *"200 6-counts in 20 min by July 1"*
- Three-point progress bar: `burpee_count_baseline` → trend projection today → `burpee_count_target`
- Weeks remaining, current phase badge (Build W1/W2/W3 | Deload), trend status badge

### Next session recommendation panel
- `Recommendation.rationale` string
- `burpee_count_suggested`, `duration_sec_suggested`, `sec_per_burpee_suggested`
- **"Build plan from this"** → opens PlannerLive pre-populated:
  - `burpee_type` from goal
  - One block, `repeat_count` derived from `burpee_count_suggested / reasonable_set_size`
  - `sec_per_burpee` from `sec_per_burpee_suggested`
  - User reviews and adjusts before saving
- **"Log free session"** → opens log form pre-filled with suggested values

### Goal management
- Create: `burpee_type`, `burpee_count_target`, `duration_sec_target`, `date_target`,
  baseline (auto-filled from most recent session of that type, or manual entry)
- Abandon goal (with confirmation dialog)
- Achieved goals shown in collapsed history section below

---

## FREE-FORM LOGGING — `/log`

Manual session entry without a plan:
- Fields: `burpee_type`, `burpee_count_actual`, `duration_sec_actual`, `note_pre`, `note_post`
- `inserted_at` defaults to today (date picker, editable)

---

## PROJECT STRUCTURE

```
lib/
  burpee_trainer/
    accounts.ex          # User auth context (get_user, authenticate_user, etc.)
    workouts.ex          # Ecto context: plans, blocks, sets, sessions
    goals.ex             # Ecto context: goals CRUD
    planner.ex           # Pure functional: plan -> timeline + summary
    progression.ex       # Pure functional: goal + sessions -> recommendation
  burpee_trainer_web/
    live/
      session_live.ex    # Live session runner
      planner_live.ex    # Plan builder/editor
      history_live.ex    # History + charts
      goals_live.ex      # Goals + recommendations
      log_live.ex        # Free-form session logging
    components/
      ...                # Shared LiveView components
priv/
  repo/migrations/
assets/
  js/
    hooks/
      burpee_hook.js     # Web Audio metronome + beep hook
      chart_hook.js      # Chart.js history chart hook
```

---

## MIX TASKS

```
mix burpee_trainer.create_user   # prompts for username + password, seeds User row
```

---

## CONSTRAINTS & PREFERENCES

- SQLite via `ecto_sqlite3`. No Postgres.
- No JavaScript frameworks. Tailwind + Phoenix LiveView + minimal vanilla JS hooks only.
- Web Audio API for all audio. No audio files, no external audio libs.
- Chart.js via CDN for history chart.
- `BurpeeTrainer.Planner` and `BurpeeTrainer.Progression` are pure functional modules —
  no Ecto, no side effects, fully unit-testable. All I/O at the edges; logic in the middle.
- Write ExUnit tests for both pure modules.
- Prefer plain `GenServer` / `Process` for concurrency. No third-party concurrency libs.
- Do not generate VS Code config files (`.vscode/`, `launch.json`, etc.).
- Apply TigerStyle naming conventions as described in the NAMING CONVENTIONS section above.
  In particular: units and qualifiers trail (`duration_sec_actual` not `actual_duration_sec`),
  no abbreviations, helper functions prefixed with their calling function name.
