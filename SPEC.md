# BurpeeTrainer — Full Project Specification

> Read this file thoroughly before doing anything.
> Generate a plan and wait for my approval before writing any code.

> Intelligence-layer note: the old PlanWizard/MILP/ScheduleSolver direction in this file is superseded by `INTELLIGENCE_LAYER.md`, which documents the current implementation.
>
> Current-contract note: **DELETION-FIRST WORKOUT LIBRARY AND COACH — CURRENT CONTRACT** below supersedes older data-model, planning, Home, recommendation, and completion passages wherever they conflict.

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
target_duration_min           -- int: user's target duration in minutes
burpee_count_target           -- int: total reps required (exact, enforced on save)
sec_per_burpee                -- float: pace (validated against physical limits)
pacing_style                  -- atom: :even | :unbroken
additional_rests              -- stored as JSON array in SQLite:
                              -- [%{rest_sec: int, target_min: int}, ...]
                              -- only valid when pacing_style == :even
has_many blocks (ordered by position)
```

> Warmup is NOT stored on the plan. It is generated on session start from the plan's
> `sec_per_burpee` and `burpee_type`. See LIVE SESSION section.

> Shave-off is NOT a user-facing concept. The solver handles rest distribution internally.

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
Solver that converts `%PlanInput{}` into a fully structured `%WorkoutPlan{}`.

### Physical pace limits (hard constraints)

Derived from the graduation landmark: maximum possible reps in 20 min.

```
six_count:  sec_per_burpee >= 1200 / 325 ≈ 3.70s  (floor, rounded up to 2dp)
navy_seal:  sec_per_burpee >= 1200 / 150 = 8.00s
```

Enforced at input time — not on save. The pace input shows the floor value and blocks
progression if violated.

### Physical floor constants

```elixir
@sec_per_burpee_floor %{
  six_count:  Float.ceil(1200 / 325, 2),   # 3.70
  navy_seal:  1200 / 150                   # 8.00
}
```

### Input struct

```elixir
%PlanInput{
  name,
  burpee_type,           -- :six_count | :navy_seal
  target_duration_min,   -- int: user's target (validated within ±5s on save)
  burpee_count_target,   -- int: exact rep count (exact match enforced on save)
  sec_per_burpee,        -- float: must be >= physical floor for burpee_type
  pacing_style,          -- :even | :unbroken
  additional_rests,      -- [%{rest_sec: int, target_min: int}]
                         -- only valid when pacing_style == :even
}
```

### Solver logic — `BurpeeTrainer.PlanWizard.generate/1`

```
Step 1: Validate physical pace limit. Return {:error, :pace_too_fast} if violated.

Step 2: Generate base block structure from pacing_style:

  :unbroken ->
    One block, one set: burpee_count = burpee_count_target, sec_per_burpee = sec_per_burpee.
    rest_sec_after_set = 0.
    No additional rests permitted (error if provided).

  :even ->
    Distribute burpee_count_target into equal sets.
    Compute rest_sec_after_set such that total duration approximates target_duration_min.
    Produces one block with repeat_count = set_count, one set per repetition.

Step 3: Inject additional rests (even pacing only):

  For each %{rest_sec, target_min} in additional_rests:
    target_sec = target_min * 60
    Find the nearest natural block boundary in the generated timeline to target_sec.
    "Nearest boundary" = the end of the set whose cumulative end time is
    closest to target_sec (either before or after).

    If nearest boundary is within 30s of target_sec:
      Split blocks at that boundary.
      Insert a zero-rep rest block of rest_sec at the split point.
    Else:
      Return {:error, {:rest_unplaceable, target_min}}

Step 4: Return {:ok, %WorkoutPlan{}} with all blocks and sets populated.
        Duration is derived — not stored separately.
```

### Public API

```elixir
BurpeeTrainer.PlanWizard.generate/1
# %PlanInput{} -> {:ok, %WorkoutPlan{}} | {:error, reason}

BurpeeTrainer.PlanWizard.validate_pace/2
# burpee_type, sec_per_burpee -> :ok | {:error, :pace_too_fast, floor_value}
```

### Tests (ExUnit)

Cover:

- even pacing: total reps match exactly, duration within ±5s of target
- unbroken: one block, one set, correct rep count
- pace at exactly the floor: accepted
- pace below floor: rejected with :pace_too_fast
- rest placed at nearest boundary within 30s: accepted, block split correctly
- rest with no boundary within 30s: rejected with :rest_unplaceable
- additional rest with unbroken pacing: rejected
- rest_unplaceable error includes which rest caused the failure

---

## PLANNER MODULE

Pure Elixir module `BurpeeTrainer.Planner`. No Ecto dependency.

### Event struct

```elixir
%Event{
  type:           :warmup_burpee | :warmup_rest | :work_burpee | :work_rest | :rest_block,
  duration_sec:   float,
  burpee_count:   integer | nil,
  sec_per_burpee: float | nil,
  label:          string
}
```

> `:rest_block` is the event type for injected additional rests (zero-rep blocks).
> There is no `:shave_rest` type — shave-off is no longer a user-facing concept.

### Timeline logic

`to_timeline/1` expands the plan into a flat list of events (warmup NOT included):

1. **Main**: expand each block by `repeat_count`, emit sets as work+rest pairs.
2. `:rest_block` events are emitted for zero-rep blocks (injected additional rests).

Warmup is handled separately via `warmup_timeline/1` — prepended at session start if user opts in.

### Warmup generation — `warmup_timeline/1`

Fixed algorithm, no user configuration:

```
Round 1: min(burpee_count_per_set_in_block_1, reps_in_1_min_at_pace) reps
Rest:    120s (hardcoded)
Round 2: same rep count as round 1
Rest:    180s (hardcoded)
→ main workout begins
```

### Public API

```elixir
BurpeeTrainer.Planner.to_timeline/1
# %WorkoutPlan{} -> [%Event{}]   (main workout only, no warmup)

BurpeeTrainer.Planner.warmup_timeline/1
# %WorkoutPlan{} -> [%Event{}]   (warmup events only, prepend to main if user opts in)

BurpeeTrainer.Planner.summary/1
# %WorkoutPlan{} -> %{burpee_count_total, duration_sec_total, blocks: [...]}
```

Helpers: `build_timeline/1`, `build_timeline_block/2`.

### Tests (ExUnit)

Cover: plan expansion, warmup generation, rest_block events, zero-rest edge cases,
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

### Architecture — client-driven execution

The server computes the timeline once on mount and pushes it to the client. The client
(`SessionHook`) owns the clock, state machine, beeps, and all UI updates. The server is
idle during the workout and only involved at save time.

```
Server: on mount, computes timeline once, pushes to client, then goes idle
Client (SessionHook): owns clock, state machine, beeps, and UI updates
  → on completion: pushes final state to server
Server: receives completion, shows save modal
```

### SessionLive — on mount

```elixir
def mount(%{"plan_id" => plan_id}, session, socket) do
  plan     = Workouts.get_plan(plan_id)
  timeline = Planner.to_timeline(plan)

  {:ok, push_event(socket, "session_ready", %{
    timeline: serialize_timeline(timeline)
  })}
end
```

### SessionLive — handles from client

```elixir
def handle_event("warmup_requested", _, socket) do
  warmup = Planner.warmup_timeline(socket.assigns.plan)
  {:noreply, push_event(socket, "warmup_ready", %{warmup: serialize_timeline(warmup)})}
end

def handle_event("session_complete", %{"main" => main, "warmup" => warmup}, socket) do
  # Show completion modal pre-filled with actual values
end
```

### What is NOT in SessionLive

- No `:timer.send_interval`
- No `handle_info(:tick)`
- No `phase_elapsed_sec` assign
- No server-side phase transition logic
- No `push_event("warn_rest_ending")`
- No `push_event("start_metronome")` / `"stop_metronome"` / `"pause_metronome"`

### State machine (client-side phases)

```
idle → warmup_burpee → warmup_rest → work_burpee → work_rest → rest_block → done
```

`rest_block` is for injected additional rest blocks (replaces the old `shave_rest`).

### SessionHook (session_hook.js)

Full client-side session runtime. Renamed from `burpee_hook.js`.

**Clock:** `performance.now()` + `requestAnimationFrame`. Not `setInterval` — avoids drift and
tab throttling.

**State machine:** walks the flat timeline array using elapsed time.

**Beeps (Web Audio API):**

- Rep beep: 880hz, 80ms, square. Fires at each rep boundary within a work phase.
- Rest-ending beep: 440hz, 400ms, sine. Fires when 5s remain in any rest phase.

**Pause/resume:** shifts `startTime` forward by pause duration so elapsed stays correct.

**Warmup flow:**

1. Show warmup prompt on tap-to-start screen.
2. If Yes: `pushEvent("warmup_requested")` → server responds with `warmup_ready` → prepend to timeline.
3. If Skip: start immediately with main timeline.

**On completion:** `pushEvent("session_complete", {main: {...}, warmup: {...}})`.

**UI updates:** direct DOM manipulation for high-frequency values (clock, rep counter)
to avoid unnecessary LiveView diffs.

### Mood input

Tap-to-start overlay: 😮‍💨 Tired (-1) / 😐 OK (0) / 💪 Hyped (+1).
Initializes AudioContext on tap (browser requirement).

### Completion modal

Pre-filled, all editable: `burpee_count_actual`, `duration_sec_actual`, `mood`,
`tags` (multi-select), `note_pre`, `note_post`.
On save: `Workouts.save_session/2` computes all derived fields, upserts `StylePerformance`.

---

## PLANS PAGE — `/plans` and `/plans/new`, `/plans/:id/edit`

### Plan list — `/plans`

```
Saved Plans
[ Plan ] [ Plan ] [ Plan ] ...
[ + New Plan ]
```

### Three-layer editor — `/plans/new` and `/plans/:id/edit`

One page, three stacked sections (no separate wizard step flow):

```
┌─────────────────────────────────────┐
│  1. BASICS                          │
│  name, style, target duration,      │
│  total reps, sec/rep, pacing        │
├─────────────────────────────────────┤
│  2. ADDITIONAL RESTS  (even only)   │
│  + Add rest                         │
│  Rest 1: 30s at min 10              │
│  Rest 2: 60s at min 18              │
├─────────────────────────────────────┤
│  3. BLOCKS                          │
│  [auto-generated, editable]         │
│  Live derived duration shown here   │
└─────────────────────────────────────┘
                              [ Save ]
```

### Layer 1 — Basics

Fields:

```
name              text input
style             two tap targets: [6-Count] [Navy Seal]
target_duration   number input (minutes). Label: "Target duration"
total_reps        number input. Label: "Total burpees"
sec_per_burpee    number input with +/- buttons.
                  Floor shown below input: "Min: 3.7s (graduation pace)"
                  Immediate error if below floor — cannot leave field.
pacing            two tap targets: [Even] [Unbroken]
                  If Unbroken selected: hide Layer 2 entirely.
```

On any change to Basics fields: re-run `PlanWizard.generate/1` and update Layer 3
(blocks) automatically. Layer 3 reflects the freshly generated structure.

### Layer 2 — Additional rests (even pacing only, hidden for unbroken)

```
[ + Add rest ]

Each rest entry:
  [__] seconds at min [__]   [× remove]
```

On any change: re-run `PlanWizard.generate/1` and update Layer 3.
If solver returns `{:error, {:rest_unplaceable, target_min}}`:
  Show inline error: "No block boundary within 30s of min Y. Adjust reps or pace."
  Layer 3 shows last valid state.

### Layer 3 — Blocks (auto-generated, user-editable)

Pre-filled from solver output. User can tweak any field.
Live derived duration shown at top of this section:

```
Derived duration: 19m 45s  (target: 20m ±5s)
Total burpees:    120       (required: 120)
```

Color coding:

- Green: both constraints satisfied
- Amber: duration within ±5s, reps exact
- Red: constraint violated (show which one)

### Save validation

```
1. burpee_count from all sets == burpee_count_target          (exact)
2. |derived_duration_sec - target_duration_min * 60| <= 5     (±5s)
3. sec_per_burpee >= floor for burpee_type                    (hard)
```

On failure, show specific error messages. Save is blocked until all three pass.

---

## OVERVIEW PAGE — `/`

New root route. Landing page after login.

### Layout (top to bottom)

```
[1] Weekly streak — current streak count + this week's progress bar
[2] Weekly calendar — last 12 weeks as a grid, goal-met highlighted
[3] Quick actions — two buttons: Run a plan, Log session
```

Weekly goal: 80 min/week.

Assigns:

```elixir
weekly_minutes:  [%{week_start, minutes, met_goal}]   # last 12 weeks, newest first
streak:          integer                               # consecutive met-goal weeks
this_week:       %{minutes, met_goal}                 # current week in progress
```

---

## HISTORY PAGE — `/history`

Three sections, top to bottom:

```
[1] Stats row — three PRs in one horizontal card (most burpees, longest session, best rate)
[2] Chart section — "Burpees over time" with series selector and time range tabs
[3] Recent sessions list — compact rows, "View all" expands in-place
```

### Chart

Chart.js via CDN. Series selector: `:six_count` | `:navy_seal`.
Time range tabs: 4W / 3M / 6M (default) / 1Y / All.
Goal line (dashed), trend line (dotted), main series line.

Assigns: `chart_series`, `chart_range`, `show_all_sessions`.

### Session list

Show 5 most recent by default. "View all sessions" expands to full list (toggle, no navigation).
Level unlock badge inline if session unlocked a level.

### Empty state

Single centered card when no sessions exist, with "Log a session" CTA.

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

## VIDEOS — `/videos` and `/videos/:id`

Videos are completely standalone — no plan, no FSM, no timer, no beeps.
They are a separate training modality: watch a Busy Dad Training video as your workout,
then log what happened when it ends.

### Video index — `/videos`

Grid of video cards showing: name, burpee_type badge, duration.
Filtered by burpee_type (tab selector at top). Click card → `/videos/:id`.

### Video player — `/videos/:id`

Full-width `<video>` element. Controls visible (native browser controls).
`src="/videos/#{video.filename}"` — routed through `VideoController` for auth check.

When video ends (`ended` DOM event), `VideoHook` sends `"video_ended"` to LiveView.
LiveView responds by sliding up a log form at the bottom of the page.

Save → `Workouts.save_session/2` with `plan_id = null`, `style_name = null`.

### Auth — X-Accel-Redirect

Video bytes never pass through Phoenix. Phoenix does the auth check; nginx serves the file.

```elixir
defmodule BurpeeTrainerWeb.VideoController do
  use BurpeeTrainerWeb, :controller

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
end
```

### VideoHook (video_hook.js)

```javascript
VideoHook = {
  mounted() {
    this.el.addEventListener("ended", () => this.pushEvent("video_ended", {}))
  }
}
```

---

## UI — SCANDINAVIAN DARK DESIGN

> Full UI spec in `SPEC_FEAT_UI.md`. Summary of key decisions:

- Cool dark palette. Blacks have a blue-gray tint.
- One accent color: electric blue (`#4A9EFF`) everywhere. Orange (`#F97316`) is data-only (chart).
- No shadows, no gradients. Flat surfaces separated by subtle borders.
- System fonts only. No custom web fonts.
- Top nav bar only. No bottom tab bar.
- Nav: `BurpeeTrainer` (wordmark, links to `/`) · `Plans` · `Log` · `History` · `Goals`

### Phase colors (session runner)

```
work:    #4A9EFF blue   (replaces green)
warmup:  #F59E0B amber
rest:    #6B8FA8 steel blue
done:    #8B77DB soft purple
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
    plan_wizard.ex         # Pure: PlanInput -> WorkoutPlan (solver)
    planner.ex             # Pure: plan -> timeline + warmup_timeline + summary
    progression.ex         # Pure: goal + sessions -> recommendation
    style_recommender.ex   # Pure: context -> top 3 StyleSuggestion
    style_generator.ex     # Pure: archetype + recommendation -> WorkoutPlan
  burpee_trainer_web/
    controllers/
      video_controller.ex  # X-Accel-Redirect auth
    live/
      overview_live.ex     # / — weekly streak, calendar, quick actions
      session_live.ex      # /session/:plan_id
      plans_live/
        index.ex           # /plans — list
        edit.ex            # /plans/new and /plans/:id/edit — three-layer editor
      history_live.ex      # /history
      goals_live.ex        # /goals
      log_live.ex          # /log
    components/
priv/
  repo/migrations/
assets/
  js/
    hooks/
      session_hook.js      # client-driven session runtime (clock, state machine, beeps)
      chart_hook.js        # Chart.js integration for history page
      video_hook.js        # fires video_ended event to LiveView on video completion
```

> `burpee_hook.js` is renamed to `session_hook.js`. The hook is registered as `SessionHook`.
> There is no longer a separate `BurpeeHook`.

---

## MIX TASKS

```
mix burpee_trainer.create_user
mix burpee_trainer.add_video NAME FILENAME BURPEE_TYPE
```

---

## DEPLOYMENT

This historical deployment section is non-operative. Deployment, rollback, host configuration,
release transfer, migrations, service management, TLS, logs, and persistent storage are owned by the
separate private infrastructure repository. Follow the authoritative instructions in `README.md`;
this repository intentionally contains no executable production deployment procedure.

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

---

## DELETION-FIRST WORKOUT LIBRARY AND COACH — CURRENT CONTRACT

This section is the current product and architecture contract. `workout_plans` is the canonical
structured-workout library, `coach_recommendations` is a small pointer projection, supervised OTP
reconciliation is transient, and `workout_sessions` owns immutable execution. Historical migration
SQL may contain predecessor names; those names do not describe current runtime behavior.

### Canonical workout library

A workout plan has one lifecycle state:

```text
draft --publish--> published --archive--> archived
```

- A `draft` is private, valid, deterministically compiled, visible in Library, refinable only through
  natural language, unstartable, and hard-deletable.
- A `published` plan is immutable, reusable, visible in Library, and startable. It may be copied to a
  new draft or archived, but not hard-deleted or edited.
- An `archived` plan remains immutable and hidden from normal selection. It cannot Start, but it may
  be copied to a new draft. Existing completed sessions retain their independent snapshots.
- Shared built-ins are system-owned published plans. User APIs cannot create or publish a built-in.

There is no generic plan update operation and no manual block/set editor. New definitions use the
canonical schema-3/solver-1 workout format. Deterministic validation, compilation, and content hashing
bind the definition, Work/Rest program, workout type, planned targets, and lifecycle transition.

### Natural-language authoring

Create and refine accept trimmed, nonblank input of at most 500 graphemes and 4,000 bytes. Each
operation performs at most one `Req.post/2`; retries and redirects are disabled, `max_tokens` is
16,384 so the provider can emit the full 16 KiB canonical definition, and response bodies are capped
at 262,144 bytes.

- Valid create output is parsed, validated, compiled, hashed, and persisted as a draft only.
- Invalid create output or provider failure persists nothing.
- Valid refine output atomically replaces only the current owned draft after a complete stale-revision
  check.
- Invalid or stale refine leaves the prior draft byte-for-byte unchanged.
- Published and archived plans must be copied to a new draft before refinement.
- No provider response publishes a workout automatically.

Provider configuration is enabled only when both `LLM_PROVIDER_URL` and `LLM_PROVIDER_API_KEY` are
present outside test. A disabled provider performs zero HTTP requests and returns a bounded domain
error while the deterministic built-in fallback remains usable.

### Recommendation pointer and candidate decision

`coach_recommendations` stores one user/slot identity, one exclusive selected published plan or
available video, an optional pending draft, a concise rationale, and timestamps. It stores product
state only: no delivery/job state or execution permission.

The coach receives bounded completed-session evidence, deterministic constraints, feedback, and the
published library. It may select an eligible existing item or propose one new workout. A proposed
workout is validated and persisted as the recommendation's pending draft.

Candidate actions are atomic:

- **Use this workout** verifies that the candidate is still the current owned draft, republishes only
  after deterministic validation, selects it, and clears `pending_draft_id` in one transaction.
- **Current workout is better** verifies the same current candidate, clears the pointer, hard-deletes
  that draft, and leaves the existing selection unchanged.

Stale selections fail closed and do not leave orphan drafts. If a selected plan is archived/missing
or a video becomes unavailable, availability convergence switches the selection to the published
built-in fallback without changing the pending draft.

### Deterministic policy and Home

The policy is authoritative and uses the user's timezone for local-day, week, Monday, and DST
boundaries.

- Weekly credited target: exactly 4,800 seconds.
- Home priority: `week_complete -> done_today -> workout_needed`.
- Monday starts a clean week; incomplete work never becomes debt.
- Weekend catch-up is eligible with at least 2,400 seconds remaining, covers the full remainder, and
  is never exploration.
- The rolling PB is the highest confirmed reps from same-type prescribed 20-minute workouts in the
  trailing six weeks.
- PB ceilings are `floor(0.75 × PB × 2)` at 40 minutes, `floor(0.60 × PB × 3)` at 60 minutes, and
  `floor(0.50 × PB × 4)` at 80 minutes.
- Exploration changes at most one meaningful dimension and occurs at most once in three completed
  workouts.
- Confirmed video duration/reps and typed session feedback are evidence; video sessions do not become
  prescribed-plan PBs.
- A started session is pinned and is never replaced by policy or reconciliation.

Home reads persisted facts and renders exactly one top-level state. During `workout_needed`, it shows
the current selection, Retry when provider work failed, and pending-candidate actions when present.
It does not compile or invoke the provider merely because Home mounted or reloaded.

### Transient supervised reconciliation

`CoachReconciler` scans persisted product facts on startup, periodically, and after lightweight
completion/date wake-ups. Provider tasks run under supervision with bounded concurrency. Task crashes
are isolated; process or application restart derives missing desired state from the database and
scans again.

Database uniqueness, expected-selection compare-and-set, and in-transaction policy revalidation make
result attachment idempotent and stale-safe. Provider failure or invalid output persists no AI draft
and leaves the published fallback selected. There are no durable jobs, outboxes, attempts, retries,
leases, claims, ownership tokens, checkpoints, watermarks, preparation rows, or authorization/use
records in the current architecture.

### Immutable started and completed sessions

Start accepts only an owned/shared published plan or an available video. The server inserts the exact
`workout_session` in `started` state before navigation and returns that session ID. The row contains:

- exclusive plan/video source identity when available;
- stable client session UUID;
- display name, workout type, and planned target snapshots;
- immutable plan Work/Rest program snapshot or exact video execution snapshot;
- content hash, source kind, and start timestamp.

The session row is the sole execution authority. Resume requires exact ownership and session ID and
loads only the stored snapshot; it never recompiles or follows a changed recommendation. Browser
execution remains deterministic and can continue offline after the page and assets load.

Completion updates that same row exactly once to `completed`, stores actual duration/reps, capture
facts, typed feedback, and completion time, then wakes reconciliation only after commit. Every
duplicate completion attempt is rejected with `:session_already_completed`; completion is not an
idempotent-success operation. Completion never calls the provider.

Plan and video snapshots are mutually exclusive. Video snapshots retain the exact catalog facts used
at Start, including name, workout type, format, duration, reps including `nil`, and media identity.
Plan archival or later video changes cannot rewrite a started or completed session.

### Feedback, pose evidence, History, and Stats

Confirmed feedback uses these typed fields:

```text
context_low_energy: boolean
context_high_energy: boolean
context_heat_affected: boolean
primary_limiter: breathing | whole_body | upper_body | legs | nil
preference_feedback: choose_again | avoid | nil
```

Pre/post notes are valid UTF-8 and at most 500 bytes each. Completed pose evidence belongs to one exact
owned completed session. Pose chunks are exact-content idempotent: a retransmission must match every
persisted immutable field and digest; a conflicting replay or a new chunk after completion fails
transactionally.

History and Stats read completed session snapshots, not mutable library rows. Archived plans,
history-only tombstones, and later catalog changes preserve display name, workout type, planned and
actual targets, notes, feedback, capture data, program/video facts, and pose associations. History
pagination orders by the compound descending cursor `{completed_at, id}`.

### Migration and operational rollback

The destructive redesign preserves users, videos, completed sessions, visible History/Stats facts,
completed pose runs/chunks, analytics, IDs, and SQLite sequences required by preserved rows. It
deletes old configurable workouts, abandoned incomplete sessions, structured-editor persistence, and
obsolete orchestration tables. Historical migration files remain immutable.

The forward rebuild runs atomically on one pinned SQLite connection after a verified backup. It
accepts only the complete predecessor or complete target shape, verifies foreign keys, removes helper
artifacts, and is operationally one-way. Rollback means restoring the verified pre-migration backup,
not reconstructing a writable predecessor schema.

The canonical rehearsal uses only `BurpeeTrainer.TestSupport.IsolatedMigrationRepo`, fixed marked
paths under `/tmp`, pool size 1 for immutable historical migrations, then a fresh pool size 5 for
representative seed, `VACUUM INTO`, redesign, verification, and restore. It never starts or
reconfigures the application Repo.

### UI and route contract

Primary authenticated destinations are Home, Library (`/workouts`), History, and Stats. Library has
separate Published and Draft sections. Published entries offer Start, Copy, and Archive; drafts offer
Refine, Publish, and Delete. Home offers Start/Resume for the selected item, **Use this workout** and
**Current workout is better** for a pending candidate, and bounded Retry around provider failure.

Plan and video Start routes create a session first and navigate to `/session/:session_id`. Session
analysis redirects safely when a row is missing or not owned. Video delivery keeps the existing
X-Accel and request-size protections.

### Explicit exclusions

The current architecture must not reintroduce equivalent concepts under new names:

- durable provider jobs, delivery events, attempts, claims, retries, leases, checkpoints, or
  watermarks;
- preparation or separate ready/preview lifecycle tables;
- execution permission, authorization, use, lane, or fingerprint entities;
- candidate ancestry graphs or rejected-candidate history;
- automatic multi-call repair;
- generic mutable plan APIs or a manual block/set editor;
- compatibility facades for deleted configured workouts.

The system remains understandable as a durable workout library, a small recommendation pointer,
supervised reconciliation, and immutable workout sessions.
