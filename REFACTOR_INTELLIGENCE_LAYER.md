# 1. Core decision

The app does **not** need a high-level MILP scheduler.

The weekly training structure is fixed:

```txt
80 min / week
no more, no less

Optimal weekly split:
  4 × 20 min sessions

Type split:
  2 × Six-Count
  2 × Navy SEAL
```

This is not configurable.

The intelligence layer should not decide:

```txt
which days to train
what time of day to train
how to rearrange the week
whether to do 3, 4, or 5 sessions
whether to change the 2+2 type split
```

The user decides when to train.

The coach only answers:

```txt
What burpee target keeps me on track toward my performance goal?
```

Then the user chooses the shape:

```txt
Even pace
Unbroken sets
Extra rest
Manual edits
```

---

# 2. New architecture

Replace the old macro/micro solver model:

```txt
ScheduleSolver
  ↓
PlanSolver
```

with:

```txt
WeeklyTrainingContract
  fixed 80 min / week, 4 × 20, 2+2 split

PerformanceModel
  turns history into current ability estimates

TrainingState
  type-specific level, fatigue, confidence, recent trend

CoachTargetPlanner
  suggests rep targets to stay on track

PlanSolver
  turns a chosen target into a concrete session

SessionReview
  compares planned vs actual and updates history
```

Full flow:

```txt
History
  ↓
PerformanceModel.build_training_state/1
  ↓
CoachTargetPlanner.suggest_targets/1
  ↓
Coach cards:
    - Stay on track: 108 six-count
    - Small step: 104 six-count
    - Push day: 114 six-count
  ↓
User chooses/tunes:
    - even / unbroken
    - extra rests
    - manual reps
  ↓
PlanSolver.solve/1
  ↓
WorkoutPlan
  ↓
SessionRunner
  ↓
SessionReview
  ↓
History
```

---

# 3. Hard rules

## Weekly contract

```elixir
@weekly_target_min 80
@standard_session_duration_min 20

@weekly_slots [
  %{burpee_type: :six_count, duration_min: 20},
  %{burpee_type: :six_count, duration_min: 20},
  %{burpee_type: :navy_seal, duration_min: 20},
  %{burpee_type: :navy_seal, duration_min: 20}
]
```

Rules:

```txt
The app's default week is always 80 min.
The default split is always 2 six-count + 2 Navy SEAL.
Coach suggestions are always for 20 min sessions.
The coach never generates 40 min catch-up sessions.
The coach never schedules days.
The coach never changes the weekly split.
```

If the user manually decides to do a 40 min session at the end of the week, that is allowed as a user decision, but it is not something the intelligence layer should prescribe.

Manual non-standard sessions should be logged and counted, but they should be treated as deviations from the canonical weekly contract.

---

# 4. Remove `ScheduleSolver`

Delete or retire:

```elixir
BurpeeTrainer.ScheduleSolver
```

Remove these concepts from the intelligence layer:

```txt
available_days
time_of_day_bucket
time_of_day_penalty
which days
time of day
calendar placement
weekly MILP scheduling
day-level optimization
session placement optimization
```

Also remove the previous flow:

```elixir
ScheduleSolver output -> scheduled session -> PlanSolver
```

The app should no longer have a solver that pretends to plan the week.

---

# 5. Add `WeeklyTrainingContract`

New module:

```elixir
BurpeeTrainer.WeeklyTrainingContract
```

Purpose:

```txt
Represent the fixed weekly training contract.
Track this week's completion against the fixed 80 min / 2+2 split.
Expose remaining standard slots.
Do not optimize or schedule.
```

## Public API

```elixir
BurpeeTrainer.WeeklyTrainingContract.contract/0
# -> %WeeklyContract{}

BurpeeTrainer.WeeklyTrainingContract.status/2
# sessions, week_start_date -> %WeeklyStatus{}

BurpeeTrainer.WeeklyTrainingContract.remaining_slots/2
# sessions, week_start_date -> [%WeeklySlot{}]

BurpeeTrainer.WeeklyTrainingContract.remaining_minutes/2
# sessions, week_start_date -> integer
```

## Structs

```elixir
%WeeklyContract{
  target_min: 80,
  standard_session_duration_min: 20,
  slots: [
    %WeeklySlot{burpee_type: :six_count, duration_min: 20},
    %WeeklySlot{burpee_type: :six_count, duration_min: 20},
    %WeeklySlot{burpee_type: :navy_seal, duration_min: 20},
    %WeeklySlot{burpee_type: :navy_seal, duration_min: 20}
  ]
}
```

```elixir
%WeeklyStatus{
  target_min: 80,
  completed_min: integer,
  remaining_min: integer,

  six_count: %{
    target_sessions: 2,
    completed_standard_sessions: integer,
    completed_min: integer,
    remaining_standard_sessions: integer
  },

  navy_seal: %{
    target_sessions: 2,
    completed_standard_sessions: integer,
    completed_min: integer,
    remaining_standard_sessions: integer
  },

  status:
    :empty
    | :in_progress
    | :complete
    | :under_target
    | :over_target
    | :non_standard
}
```

## Behavior

A normal completed 20 min six-count session consumes one six-count slot.

A normal completed 20 min Navy SEAL session consumes one Navy SEAL slot.

A manually logged 40 min session counts toward weekly minutes, but should mark the week as `:non_standard` if it does not match the canonical 4 × 20 structure.

Example:

```txt
Completed:
  Six-count 20 min
  Six-count 20 min
  Navy SEAL 40 min

Weekly minutes:
  80 / 80 complete

Canonical split:
  non-standard, because the user manually used one 40 min Navy SEAL session
  instead of two 20 min Navy SEAL sessions
```

Do not auto-repair this. Do not suggest weird compensating sessions. Just reflect reality.

---

# 6. Performance goals are separate from weekly volume

The weekly volume contract is fixed.

User-set goals are **performance goals**, not weekly schedule goals.

Example performance goals:

```txt
Reach 325 six-count burpees in 20 min
Reach 150 Navy SEAL burpees in 20 min
Reach 160 six-count burpees in 20 min by a given date
```

Goals are type-specific.

Do not use one shared goal for six-count and Navy SEAL.

## New struct

```elixir
%PerformanceGoal{
  id: integer | nil,
  burpee_type: :six_count | :navy_seal,

  target_reps: integer,
  target_duration_min: 20,

  start_reps: integer | nil,
  start_date: Date.t() | nil,
  target_date: Date.t() | nil,

  status: :active | :paused | :completed
}
```

The app may have one active goal per burpee type:

```elixir
%PerformanceGoal{
  burpee_type: :six_count,
  target_reps: 325,
  target_duration_min: 20
}
```

```elixir
%PerformanceGoal{
  burpee_type: :navy_seal,
  target_reps: 150,
  target_duration_min: 20
}
```

---

# 7. Add `PerformanceModel`

New module:

```elixir
BurpeeTrainer.PerformanceModel
```

Purpose:

```txt
Turn session history into type-specific ability estimates.
```

It should not schedule anything.

It should not create workout plans.

It should answer:

```txt
What does the user currently seem capable of for this burpee type?
How confident are we?
Is the recent trend improving, flat, or declining?
```

## Public API

```elixir
BurpeeTrainer.PerformanceModel.current_capacity/3
# history, burpee_type, duration_min -> %CurrentCapacity{}

BurpeeTrainer.PerformanceModel.build_training_state/1
# history -> %TrainingState{}
```

## Current capacity

```elixir
%CurrentCapacity{
  burpee_type: :six_count | :navy_seal,
  duration_min: 20,

  estimated_reps: integer,
  recent_best_reps: integer | nil,
  recent_completed_avg_reps: float | nil,
  last_successful_reps: integer | nil,

  trend: :improving | :flat | :declining | :unknown,
  confidence: float
}
```

Simple first version:

```elixir
estimated_reps =
  0.50 * recent_completed_avg_reps +
  0.30 * recent_best_reps +
  0.20 * last_successful_reps
```

Then round to a human target:

```elixir
round_capacity(estimated_reps)
```

Suggested rounding:

```txt
below 50 reps: nearest 1
50–150 reps: nearest 2 or 5
above 150 reps: nearest 5
```

## Non-standard sessions

Manual 40 min sessions should count toward weekly minutes.

For performance estimation, do not blindly treat a 40 min session as a 20 min capacity result.

Preferred behavior:

```txt
If the session has block-level data:
  derive the best comparable 20 min window, or estimate 20 min equivalent cautiously.

If the session has only total duration and total reps:
  include it in volume history but downweight/exclude it from 20 min capacity.
```

---

# 8. Add `TrainingState`

New struct:

```elixir
%TrainingState{
  level_by_type: %{
    six_count: level_atom,
    navy_seal: level_atom
  },

  current_capacity_by_type: %{
    six_count: %CurrentCapacity{},
    navy_seal: %CurrentCapacity{}
  },

  fatigue: :low | :normal | :high | :unknown,
  recent_completion_rate: float,
  recent_missed_sessions: integer,
  confidence: float
}
```

Important:

```txt
Six-count and Navy SEAL levels are separate.
```

A user can be level 1C for six-count and level 1A for Navy SEAL.

Do not use one global level for both types.

---

# 9. Replace `ScheduleSolver` with `CoachTargetPlanner`

New module:

```elixir
BurpeeTrainer.CoachTargetPlanner
```

Purpose:

```txt
Given a performance goal and recent history, suggest rep targets.
```

It answers:

```txt
What number should I aim for in my next 20 min session to stay on target?
```

It does not answer:

```txt
When should I train?
How many sessions this week?
Should I do a 40 min catch-up?
What time of day?
What set size?
What rest length?
```

---

# 10. `CoachTargetPlanner` input

```elixir
%CoachTargetInput{
  goal: %PerformanceGoal{},
  history: [Session.t()],
  training_state: %TrainingState{},
  weekly_status: %WeeklyStatus{},

  burpee_type: :six_count | :navy_seal,
  target_duration_min: 20,

  today: Date.t()
}
```

`target_duration_min` is always `20` for coach-generated suggestions.

Do not generate 40 min coach targets.

---

# 11. `CoachTargetPlanner` output

The planner returns suggestions.

```elixir
%CoachTargetSuggestion{
  kind:
    :on_track
    | :recommended
    | :safe_progress
    | :stretch
    | :maintenance
    | :deload,

  title: String.t(),

  burpee_type: :six_count | :navy_seal,
  target_duration_min: 20,
  burpee_count_target: integer,

  current_estimate_reps: integer | nil,
  goal_reps: integer,

  status: :ahead | :on_track | :behind | :unknown,
  risk: :low | :normal | :high,

  confidence: float,

  rationale: [String.t()],

  plan_input_defaults: %{
    pacing_style: :even | :unbroken,
    additional_rests: list()
  }
}
```

---

# 12. Suggestion kinds

## `:on_track`

The mathematically relevant target for staying on the goal curve.

This should exist even if it is aggressive.

Example:

```elixir
%CoachTargetSuggestion{
  kind: :on_track,
  title: "Stay on track",
  burpee_type: :six_count,
  target_duration_min: 20,
  burpee_count_target: 108,
  current_estimate_reps: 104,
  goal_reps: 160,
  status: :on_track,
  risk: :normal,
  confidence: 0.82,
  rationale: [
    "Your current estimate is 104 six-count burpees in 20 min.",
    "108 keeps you on pace for your goal."
  ],
  plan_input_defaults: %{
    pacing_style: :even,
    additional_rests: []
  }
}
```

## `:recommended`

The coach’s preferred target for today.

Usually this equals `:on_track`.

If the on-track target is too aggressive, `:recommended` should be safer.

Example:

```txt
On-track target:
  124 reps

Recommended today:
  112 reps

Reason:
  124 is a large jump from your recent best.
```

## `:safe_progress`

A small step up from recent successful performance.

```elixir
%CoachTargetSuggestion{
  kind: :safe_progress,
  title: "Small step",
  burpee_count_target: 104,
  risk: :low
}
```

## `:stretch`

A push-day target.

```elixir
%CoachTargetSuggestion{
  kind: :stretch,
  title: "Push day",
  burpee_count_target: 114,
  risk: :high
}
```

## `:maintenance`

Repeat or slightly under recent successful performance.

Useful after fatigue, missed sessions, illness, or failed sessions.

```elixir
%CoachTargetSuggestion{
  kind: :maintenance,
  title: "Repeat last success",
  burpee_count_target: 100,
  risk: :low
}
```

## `:deload`

Lower target after repeated failures or high fatigue.

```elixir
%CoachTargetSuggestion{
  kind: :deload,
  title: "Easy day",
  burpee_count_target: 88,
  risk: :low
}
```

---

# 13. Target calculation

The target planner should:

```txt
1. Estimate current capacity for the burpee type.
2. Compare current capacity to the active performance goal.
3. Estimate remaining sessions toward the goal.
4. Compute the next target needed to stay on the curve.
5. Clamp unsafe jumps for the recommended target.
6. Return multiple suggestions.
```

Pseudo-code:

```elixir
def suggest_targets(%CoachTargetInput{} = input) do
  current =
    PerformanceModel.current_capacity(
      input.history,
      input.burpee_type,
      input.target_duration_min
    )

  sessions_remaining =
    GoalProgress.sessions_remaining(
      input.goal,
      input.today,
      sessions_per_week_for_type: 2
    )

  raw_on_track_target =
    GoalProgress.required_next_target(
      current_reps: current.estimated_reps,
      goal_reps: input.goal.target_reps,
      sessions_remaining: sessions_remaining
    )

  recommended_target =
    Progression.clamp_recommended_target(
      raw_on_track_target,
      current_capacity: current,
      training_state: input.training_state,
      burpee_type: input.burpee_type
    )

  SuggestionBuilder.build(
    input,
    current,
    raw_on_track_target,
    recommended_target
  )
end
```

## Required next target

```elixir
required_gain_per_session =
  (goal_reps - current_reps) / max(sessions_remaining, 1)

next_target =
  current_reps + required_gain_per_session
```

Example:

```txt
Current estimate: 104 reps
Goal: 160 reps
Sessions remaining: 14

Required gain:
  (160 - 104) / 14 = 4 reps/session

On-track target:
  108 reps
```

## Clamp unsafe recommended jumps

The `:on_track` suggestion should preserve the true number.

The `:recommended` suggestion may be clamped.

Example rules:

```elixir
@max_jump_ratio %{
  low: 0.03,
  normal: 0.06,
  high: 0.10
}
```

For current estimate `104`:

```txt
Low-risk:     107
Normal:       110
Aggressive:   114
```

If the raw on-track target is `124`, return:

```txt
Stay on track:
  124 reps
  risk: high

Recommended:
  110 reps
  risk: normal
```

The UI should be honest:

```txt
124 keeps you on the original curve.
110 is the safer target today.
```

---

# 14. `CoachTargetPlanner` should generate suggestions per type

Because the weekly split is fixed:

```txt
2 × Six-Count
2 × Navy SEAL
```

The coach screen can show one target set for each type:

```txt
Coach

Six-count
  Stay on track: 108 reps
  Small step: 104 reps
  Push day: 114 reps

Navy SEAL
  Stay on track: 42 reps
  Small step: 40 reps
  Push day: 46 reps
```

The app should not decide which one the user must do today.

The user chooses.

The weekly status can show what remains:

```txt
This week
40 / 80 min

Six-count
1 / 2 sessions

Navy SEAL
1 / 2 sessions
```

But this is status, not scheduling.

---

# 15. Interaction with `PlanSolver`

When the user accepts a coach suggestion, create a `PlanInput`.

```elixir
%PlanInput{
  name: suggestion.title,
  burpee_type: suggestion.burpee_type,
  target_duration_min: 20,
  burpee_count_target: suggestion.burpee_count_target,
  pacing_style: user_selected_or_default_pacing,
  additional_rests: user_selected_additional_rests,
  level: training_state.level_by_type[suggestion.burpee_type]
}
```

The user may tune:

```txt
even / unbroken
extra rests
target reps
set structure
rest structure
manual block edits
```

If the user changes the target below the coach suggestion, do not block them.

Show a soft note:

```txt
8 reps below coach target.
Still useful as a maintenance session.
```

If the user changes above the coach suggestion:

```txt
6 reps above coach target.
Treat as a push day.
```

---

# 16. Refactor `PlanSolver`

`PlanSolver` should not be a raw MILP.

The previous formulation had nonlinear constraints:

```txt
set_size * set_count
set_size * sec_per_burpee * set_count
floor / sec_per_burpee
```

Instead, use:

```txt
candidate generation + deterministic scoring
```

The search space is tiny and the result should feel human.

## Module

```elixir
BurpeeTrainer.PlanSolver
```

## Input

```elixir
%PlanInput{
  name: String.t() | nil,

  burpee_type: :six_count | :navy_seal,
  target_duration_min: integer,
  burpee_count_target: integer,

  pacing_style: :even | :unbroken,

  additional_rests: [
    %{rest_sec: integer, target_min: integer}
  ],

  level: level_atom
}
```

`sec_per_burpee` is not a user input.

## Output

```elixir
%PlanSolution{
  set_pattern: [integer],
  sec_per_burpee: float,
  rest_pattern_sec: [integer | float],

  duration_sec: float,
  burpee_count: integer,

  pacing_style: :even | :unbroken,
  burpee_type: :six_count | :navy_seal,

  plan: %WorkoutPlan{},

  metadata: %PlanSolverMetadata{}
}
```

## Candidate generation

Generate human-shaped candidates:

```elixir
for set_pattern <- generate_set_patterns(total_reps),
    pace <- pace_candidates(burpee_type, level),
    rest_pattern <- derive_rest_pattern(target_duration, set_pattern, pace, additional_rests),
    feasible?(set_pattern, pace, rest_pattern, input) do
  score_candidate(set_pattern, pace, rest_pattern, input)
end
|> Enum.min_by(& &1.score)
```

## Hard invariants

Every solution must satisfy:

```elixir
sum(solution.set_pattern) == input.burpee_count_target

abs(solution.duration_sec - input.target_duration_min * 60) <= 5

solution.sec_per_burpee >=
  PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, input.level)

solution.sec_per_burpee <=
  PaceModel.slowest_useful_sec_per_rep(input.burpee_type, input.level)
```

Rest after the final set should not count unless explicitly modeled.

Correct duration formula:

```elixir
duration_sec =
  total_reps * sec_per_burpee
  + sum(rest_after_each_non_final_set)
  + sum(additional_explicit_rest_blocks)
```

Do not use:

```elixir
rest_sec * set_count
```

because that incorrectly counts rest after the final set.

---

# 17. Type-specific pace model

Add:

```elixir
BurpeeTrainer.PaceModel
```

Do not use one shared level table for six-count and Navy SEAL.

## Absolute fastest standards

```elixir
@absolute_fastest_sec_per_rep %{
  six_count: 3.70,
  navy_seal: 8.00
}
```

## Level multipliers

```elixir
@level_multiplier %{
  level_1a:  2.15,
  level_1b:  1.90,
  level_1c:  1.62,
  level_1d:  1.49,
  level_2:   1.35,
  level_3:   1.22,
  level_4:   1.08,
  graduated: 1.00
}
```

## API

```elixir
def fastest_recommended_sec_per_rep(burpee_type, level) do
  @absolute_fastest_sec_per_rep[burpee_type] * @level_multiplier[level]
end
```

Example:

```txt
Six-count level 1C:
  3.70 * 1.62 = ~6.0s / rep

Navy SEAL level 1C:
  8.00 * 1.62 = ~13.0s / rep
```

Also expose:

```elixir
PaceModel.slowest_useful_sec_per_rep/2
PaceModel.pace_range_sec_per_rep/2
```

Example:

```elixir
def pace_range_sec_per_rep(type, level) do
  fastest = fastest_recommended_sec_per_rep(type, level)
  slowest = fastest * 1.45
  {fastest, slowest}
end
```

---

# 18. Fix unbroken semantics

Do not define unbroken as:

```txt
set_count = 1
set_size = total reps
rest = 0
```

That creates one giant 20 min set.

Instead:

```txt
Unbroken = rep-boxed sets.
Even = time-boxed pacing.
```

## Even pacing

Example:

```txt
24 burpees over 4:00
show ahead/behind
```

Runner display:

```txt
Block 4 / 12
Even pace
24 burpees over 4:00

18 / 24 reps
+0:16 ahead
```

## Unbroken pacing

Example:

```txt
12 burpees
finish the set
rest earned
```

Runner display:

```txt
Block 3 / 12
Unbroken set
12 burpees

8 / 12 reps
Finish the set
```

After completion:

```txt
Set complete
0:34 rest earned
```

Unbroken still has multiple sets.

Example solution:

```elixir
%PlanSolution{
  pacing_style: :unbroken,
  set_pattern: [9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9],
  rest_pattern_sec: [30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 0]
}
```

---

# 19. Allow non-uniform set patterns

Do not require:

```txt
set_size * set_count = total_reps
```

That forces ugly plans for awkward rep targets.

Use:

```elixir
sum(set_pattern) == burpee_count_target
```

Examples:

```elixir
[9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9]
# 108 reps
```

```elixir
[9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 8]
# 107 reps
```

```elixir
[10, 10, 10, 10, 10, 9, 9, 9, 10, 10, 10]
# human-shaped mixed set pattern
```

Prefer human-shaped numbers:

```txt
4, 5, 6, 8, 9, 10, 12, 15
```

depending on burpee type and level.

---

# 20. Additional rests

Additional rests are explicit user tuning.

They are not a high-level coach decision.

Allow additional rests for both pacing styles.

```elixir
additional_rests: [
  %{rest_sec: 60, target_min: 10}
]
```

Placement rule:

```txt
Place at the nearest block/set boundary within 30 seconds.
If no boundary is within 30 seconds, return a structured error with suggestions.
```

For even pacing:

```txt
Insert rest at nearest time block boundary.
```

For unbroken:

```txt
Insert rest after the nearest completed set.
```

---

# 21. Plan scoring

Use a normalized score, not a raw MILP objective.

```elixir
score =
  0.35 * pace_score +
  0.25 * rest_score +
  0.20 * set_pattern_score +
  0.10 * roundness_score +
  0.10 * history_score
```

Where:

```txt
pace_score
  distance from preferred pace range

rest_score
  distance from useful rest range

set_pattern_score
  how appropriate the set sizes are for level/type

roundness_score
  prefer human numbers and clean rests

history_score
  prefer structures similar to previous successful sessions
```

Avoid technically optimal but ugly plans:

```txt
7 reps × 17 sets
13.64s rest
5.83s / rep
```

Prefer human plans:

```txt
12 × 9 reps
30s rest
6.0s / rep
```

---

# 22. Plan solver metadata

Every generated solution should include metadata.

```elixir
%PlanSolverMetadata{
  solver_version: "intelligence-v2",
  input: %PlanInput{},

  chosen_candidate_score: float,
  rejected_candidate_count: integer,

  objective_breakdown: %{
    pace: float,
    rest: float,
    set_pattern: float,
    roundness: float,
    history: float
  },

  explanation: [
    "9-rep sets match your recent successful six-count sessions.",
    "6.0s/rep is within your level 1C range.",
    "30s rest keeps the session inside 20 minutes."
  ]
}
```

Useful for debugging and future coach explanations.

---

# 23. UI refactor

## Replace schedule UI with coach suggestions

Do not show:

```txt
Monday: Six-count
Wednesday: Navy SEAL
Friday: Six-count
Sunday: Navy SEAL
```

Instead show:

```txt
This week

40 / 80 min

Six-count
1 / 2 sessions

Navy SEAL
1 / 2 sessions
```

Then:

```txt
Coach

Six-count
Stay on track
108 burpees · 20 min

Navy SEAL
Stay on track
42 burpees · 20 min
```

The user chooses what to do.

## Coach card

Example:

```txt
Stay on track

108 six-count burpees
20 min

You are on pace for your goal.
This is +4 from your current estimate.

[Plan this]
```

Secondary suggestions:

```txt
Small step
104 burpees

Push day
114 burpees

Repeat last success
100 burpees
```

## Planner screen

When a suggestion is accepted:

```txt
Target
108 six-count burpees
20 min

Shape
[Even pace] [Unbroken]

Extra rest
[+ Add rest]
```

Then show generated structure:

```txt
Recommended structure

12 sets × 9 burpees
30s rest between sets
108 total · 20 min
```

Expanded “why”:

```txt
Why this?

Level 1C · six-count
Pace estimate: 6.0s / rep
Fits your 20 min target
Matches recent successful set sizes
```

Do not make the default UI too solver-y.

Avoid leading with:

```txt
Solver chose:
Pace: 5.8s / rep
Set size: 9 reps
Rest: 28s / set
```

That can exist behind an expanded details section.

---

# 24. Manual deviations

The app should allow manual decisions.

Examples:

```txt
User chooses 40 min session.
User chooses only six-count this week.
User lowers the coach target.
User raises the coach target.
User adds extra rest.
```

But the intelligence layer should not create those decisions automatically.

Rules:

```txt
Coach-generated sessions are always 20 min.
Coach-generated targets respect the active performance goal.
Weekly contract status always reflects 80 min target.
Manual deviations are logged honestly.
No automatic make-up scheduling.
No automatic 40 min suggestions.
No automatic split repair.
```

Example UI copy:

```txt
40 min manual session
Counts toward this week's 80 min.
This is outside the standard 4 × 20 structure.
```

---

# 25. Save validation

## Workout plan validation

```txt
sum(burpee_count from all work blocks) == burpee_count_target
abs(derived_duration_sec - target_duration_min * 60) <= 5
pace is within type-specific level range
additional rests are placed at valid boundaries
```

## Weekly status validation

The app should compute:

```txt
completed_min
remaining_min
over/under status
canonical split status
```

But do not block manual logs unless they are invalid data.

Recommended behavior:

```txt
Coach suggestions stop when weekly target is complete.
Manual logging can still happen, but the week becomes over-target or non-standard.
```

---

# 26. Structured errors

Return repairable errors.

Do not return only atoms like:

```elixir
{:error, :pace_unsustainable}
```

Use:

```elixir
{:error,
 %PlanSolver.Infeasible{
   reason: :pace_unsustainable,
   required_sec_per_rep: 4.9,
   fastest_allowed_sec_per_rep: 6.0,
   suggestions: [
     %{change: :reduce_reps, value: 96},
     %{change: :increase_duration_min, value: 23},
     %{change: :switch_pacing_style, value: :unbroken},
     %{change: :add_extra_rest, value: %{rest_sec: 60, target_min: 10}}
   ]
 }}
```

UI example:

```txt
108 reps is too aggressive for level 1C in 20 min.

Try:
96 reps
or
keep 108 reps and add more rest
```

For coach targets:

```elixir
{:error,
 %CoachTargetPlanner.NoActiveGoal{
   burpee_type: :six_count,
   message: "No active six-count performance goal."
 }}
```

---

# 27. Module map

Final module set:

```elixir
BurpeeTrainer.WeeklyTrainingContract
BurpeeTrainer.PerformanceModel
BurpeeTrainer.TrainingState
BurpeeTrainer.CoachTargetPlanner
BurpeeTrainer.PaceModel
BurpeeTrainer.PlanSolver
BurpeeTrainer.SessionReview
```

Remove or retire:

```elixir
BurpeeTrainer.ScheduleSolver
BurpeeTrainer.PlanWizard
```

Rename:

```txt
PlanWizard -> PlanSolver
ScheduleSolver -> removed/replaced by CoachTargetPlanner
```

---

# 28. Data model changes

## Add or update `performance_goals`

```elixir
create table(:performance_goals) do
  add :burpee_type, :string, null: false
  add :target_reps, :integer, null: false
  add :target_duration_min, :integer, null: false, default: 20

  add :start_reps, :integer
  add :start_date, :date
  add :target_date, :date

  add :status, :string, null: false, default: "active"

  timestamps()
end
```

Constraint:

```txt
Only one active goal per burpee type.
```

## Do not add schedule tables

Do not add:

```txt
scheduled_sessions
planned_week_days
time_of_day_preferences
availability_windows
```

Those are intentionally out of scope.

## Plan metadata

Add metadata to workout plans or generated plans:

```elixir
add :coach_suggestion_kind, :string
add :coach_target_reps, :integer
add :plan_solver_metadata, :map
```

Or store metadata in a separate table if cleaner.

---

# 29. Tests

## Weekly contract tests

```txt
contract is always 80 min
contract always has 4 slots
contract always has 2 six-count slots
contract always has 2 Navy SEAL slots
normal 20 min session consumes one matching slot
manual 40 min session counts toward minutes but marks week non-standard
coach suggestions stop when 80 min is complete
```

## Coach target tests

```txt
does not output days
does not output time of day
does not output 40 min sessions
uses 20 min target duration
generates type-specific suggestions
uses two sessions per week per type for goal pacing
returns on-track suggestion
returns recommended suggestion
marks aggressive on-track target as high risk
behind/ahead/on-track status works
no active goal returns structured error
```

## Performance model tests

```txt
capacity is type-specific
six-count history does not affect Navy SEAL capacity
recent sessions are weighted more than old sessions
manual 40 min sessions are not blindly treated as 20 min capacity
confidence is lower with little history
```

## Pace model tests

```txt
six-count level 1C fastest pace is about 6.0s/rep
Navy SEAL level 1C fastest pace is about 13.0s/rep
graduated equals absolute fastest standard
lower levels never get faster allowed pace than higher levels
```

## Plan solver tests

```txt
total reps are exact
duration is within ±5s
pace is within type-specific level range
no final rest is counted unless explicit
non-uniform set patterns are allowed
unbroken creates multiple rep-boxed sets
even creates time-boxed pacing blocks
additional rests work for even
additional rests work for unbroken
invalid extra rest placement returns structured error
manual edits revalidate
```

---

# 30. Remove from previous spec

Remove:

```txt
ScheduleSolver
MILP weekly planner
available_days
time_of_day_bucket
time_of_day_penalty
StylePerformance time-of-day coefficients
scheduled session tap handler
solver-selected days
solver-selected times
solver-selected weekly structure
```

Remove from Layer 1:

```txt
sec_per_burpee input
```

Remove from high-level planner:

```txt
target_duration configurability
weekly minutes configurability
session count configurability
type split configurability
```

Keep target duration editable only as a manual planner override, not as a coach-generated behavior.

---

# 31. Final behavior

The app should feel like this:

```txt
Weekly contract:
  80 min.
  4 × 20.
  2 six-count.
  2 Navy SEAL.

Coach:
  “108 six-count burpees keeps you on target.”

User:
  “Make that even pace.”
  or
  “Make it unbroken.”
  or
  “Add extra rest.”
  or
  “I’ll do 40 min manually today.”

PlanSolver:
  “12 × 9, 30s rest, 20 min.”

Runner:
  “Block 3 / 12 — 9 burpees.”
```

The intelligence layer becomes smaller, clearer, and more honest:

```txt
WeeklyTrainingContract tracks the fixed week.
CoachTargetPlanner suggests the number.
PlanSolver structures the session.
The user owns timing and manual deviations.
```
