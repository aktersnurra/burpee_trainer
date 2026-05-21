# Full Patch — BurpeeTrainer Intelligence Layer Spec

This patch updates the original Intelligence Layer Domain Spec with the latest domain decisions:

- weekly goal is 80 minutes
- standard week is 4 × 20-minute sessions
- optimal weekly mix is 2 six-count sessions and 2 navy-seal sessions
- navy seals are materially slower and higher-fatigue than six-counts
- default planning is time-budget-first, not rep-target-first
- “unbroken” is the vocabulary to use instead of “burst”
- PlanSolver remains MILP-based
- ScheduleSolver remains MILP-based
- StyleRecommender remains Bayesian

---

# 1. Global domain assumptions

## Weekly training target

The default weekly goal is:

```txt
weekly_training_time_target = 80 minutes
session_count_per_week = 4
session_duration_target = 20 minutes
````

The standard week is:

```txt
4 sessions × 20 minutes = 80 minutes/week
```

## Weekly burpee-type composition

The optimal default weekly mix is:

```txt
2 sessions = :six_count
2 sessions = :navy_seal
```

This is a ScheduleSolver responsibility.

## Burpee types

Burpee type materially affects pace, fatigue, expected reps, and progression.

```txt
:six_count
  movement:
    down → pushup → up

  faster
  lower fatigue per rep
  higher expected reps per 20 minutes

:navy_seal
  movement:
    down
    pushup
    one knee to stomach
    back to pushup position
    pushup
    other knee to stomach
    back to pushup position
    pushup
    up to standing

  slower
  higher fatigue per rep
  lower expected reps per 20 minutes
```

Six-count and navy-seal sessions must not share the same pace ceilings, set-size bounds, fatigue costs, or progression assumptions.

---

# 2. Updated system map

The system has five modules:

```txt
ScheduleSolver          MILP
StyleRecommender        Bayesian
StyleConstraintMapper   deterministic rules
PlanSolver              MILP
SessionAnalyzer         deterministic feedback normalization
```

Each layer answers one question:

```txt
ScheduleSolver:
  Which four 20-minute sessions should this week contain?

StyleRecommender:
  Which workout style works best for this user/context?

StyleConstraintMapper:
  What solver constraints does that style imply?

PlanSolver:
  How should this 20-minute session be structured?

SessionAnalyzer:
  What happened, and what learning signals should be saved?
```

---

# 3. ScheduleSolver — MILP

## Question

Given the user’s goal, level, recent history, availability, progression state, and adherence patterns, how should the system allocate this week’s four 20-minute sessions?

## Timescale

Weeks to months.

## Domain

Mixed-integer linear optimization over a rolling training horizon.

## Default planning mode

ScheduleSolver is **time-budget-first**.

Default mode:

```txt
80 minutes/week
4 sessions/week
20 minutes/session
2 six-count sessions/week
2 navy-seal sessions/week
```

Rep targets are derived from:

```txt
burpee_type
level
target_intensity
recent performance
fatigue-adjusted progression
```

Rep targets are not the primary weekly objective unless the user explicitly sets a rep-count goal.

## Inputs

```elixir
%{
  goal: %{
    weekly_training_time_target_min: 80,
    session_count_target: 4,
    session_duration_target_min: 20,

    # optional explicit rep goal
    burpee_count_target: integer() | nil,
    date_target: Date.t() | nil
  },

  recent_sessions: [WorkoutSession.t()],
  progression: Progression.t(),

  available_days: [
    :monday | :tuesday | :wednesday | :thursday |
    :friday | :saturday | :sunday
  ],

  level: Level.t(),

  adherence_coefficients: %{
    {day_of_week, time_of_day_bucket, burpee_type, level} => float()
  },

  pace_ceilings: %{
    {level, burpee_type} => PaceCeiling.t()
  },

  fatigue_costs: %{
    burpee_type => FatigueCost.t()
  },

  constraints: %{
    session_count_target: 4,
    session_duration_target_min: 20,
    weekly_duration_target_min: 80,

    preferred_sessions_by_type: %{
      six_count: 2,
      navy_seal: 2
    },

    min_recovery_gap_hours: integer(),
    max_weekly_fatigue_increase_pct: float(),
    deload_frequency_weeks: integer() | nil
  }
}
```

## Outputs

```elixir
%SchedulePlan{
  horizon_weeks: [
    %PlannedWeek{
      week_start_date: Date.t(),

      planned_duration_min: 80,
      planned_session_count: 4,

      planned_sessions_by_type: %{
        six_count: 2,
        navy_seal: 2
      },

      projected_reps_by_type: %{
        six_count: integer(),
        navy_seal: integer()
      },

      projected_fatigue_units: float(),

      sessions: [
        %PlannedSession{
          date: Date.t(),
          day_of_week: atom(),

          burpee_type: :six_count | :navy_seal,

          duration_target_min: 20,
          burpee_count_target: integer(),

          time_of_day_bucket: :morning | :afternoon | :evening | :night,

          target_intensity: :easy | :moderate | :hard
        }
      ]
    }
  ]
}
```

## Decision variables

```txt
x[d, t, b] ∈ {0,1}
  Whether to schedule a session on day d, time bucket t, burpee type b.

reps[d, b] ∈ Z≥0
  Estimated burpees assigned to day d for type b.

fatigue_units[d, b] ≥ 0
  Fatigue-adjusted load for day d/type b.

weekly_duration[w] ∈ Z≥0
  Planned weekly minutes.

weekly_fatigue[w] ≥ 0
  Planned fatigue-adjusted weekly load.

intensity[d, k] ∈ {0,1}
  Whether day d uses intensity k.
```

## Hard constraints

```txt
Only schedule on available days.

At most one session per day.

Each scheduled session has duration_target_min = 20.

Default total weekly session count = 4.

Default total weekly duration = 80 minutes.

Default weekly type split:
  2 sessions :six_count
  2 sessions :navy_seal

Respect minimum recovery gaps.

Daily fatigue must not exceed level-based capacity.

Weekly fatigue increase must not exceed max_weekly_fatigue_increase_pct.

Burpee type must be compatible with current level.

Estimated reps must be computed using burpee-type-specific pace ceilings.
```

## Soft fallback behavior

If the optimal 2 + 2 split is infeasible because of level, fatigue, recovery, or availability, ScheduleSolver may relax the type split.

Fallback priority:

```txt
preferred:
  2 six-count + 2 navy-seal

fallback 1:
  3 six-count + 1 navy-seal

fallback 2:
  4 six-count + 0 navy-seal

fallback 3:
  fewer than 4 sessions only if availability or recovery makes 4 impossible
```

Do not schedule more than two navy-seal sessions per week unless explicitly requested.

## Weekly composition constraints

Hard version:

```txt
Σ_{d ∈ w, t} x[d, t, :six_count] = 2

Σ_{d ∈ w, t} x[d, t, :navy_seal] = 2

Σ_{d ∈ w, t, b} x[d, t, b] = 4
```

Soft version with slack:

```txt
Σ x[d, t, :six_count] + six_count_deficit[w] ≥ 2

Σ x[d, t, :navy_seal] + navy_seal_deficit[w] ≥ 2

Σ x[d, t, :navy_seal] - navy_seal_excess[w] ≤ 2

Σ x[d, t, b] + session_count_deficit[w] ≥ 4
```

Penalty priority:

```txt
highest:
  session_count_deficit_penalty

high:
  navy_seal_excess_penalty

medium:
  navy_seal_deficit_penalty

low-medium:
  six_count_deficit_penalty
```

## Objective

ScheduleSolver minimizes:

```txt
goal_shortfall_penalty
+ recovery_violation_penalty
+ excessive_weekly_fatigue_jump_penalty
+ poor_adherence_time_slot_penalty
+ poor_day_distribution_penalty
+ excessive_intensity_penalty
+ deload_deviation_penalty
+ type_split_violation_penalty
+ session_count_deficit_penalty
```

## Responsibilities

ScheduleSolver decides:

```txt
which four sessions happen this week
which days they happen
which time-of-day bucket is recommended
which burpee type each session uses
whether each session is easy, moderate, or hard
estimated rep target per 20-minute session
weekly fatigue-adjusted load
```

ScheduleSolver does not decide:

```txt
sets
pace
rests
block structure
workout style
```

Only the current week is actionable. Future weeks are projections.

---

# 4. Burpee-type pace and fatigue models

## PaceCeiling

Pace ceilings must be keyed by both level and burpee type.

```elixir
%PaceCeiling{
  level: Level.t(),
  burpee_type: :six_count | :navy_seal,

  comfortable_sec_per_rep: float(),
  challenging_sec_per_rep: float(),
  aggressive_sec_per_rep: float()
}
```

Example shape only:

```elixir
%{
  {:level_1c, :six_count} => %PaceCeiling{
    comfortable_sec_per_rep: 7.0,
    challenging_sec_per_rep: 6.0,
    aggressive_sec_per_rep: 5.2
  },

  {:level_1c, :navy_seal} => %PaceCeiling{
    comfortable_sec_per_rep: 18.0,
    challenging_sec_per_rep: 15.0,
    aggressive_sec_per_rep: 12.5
  }
}
```

Lower seconds per rep means faster and harder.

## FatigueCost

Fatigue must be type-adjusted.

```elixir
%FatigueCost{
  burpee_type: :six_count | :navy_seal,
  fatigue_units_per_rep: float()
}
```

Example shape only:

```elixir
%{
  :six_count => %FatigueCost{fatigue_units_per_rep: 1.0},
  :navy_seal => %FatigueCost{fatigue_units_per_rep: 2.5}
}
```

ScheduleSolver should use fatigue units, not raw reps, when comparing or progressing mixed weeks.

## WeeklyLoad

```elixir
%WeeklyLoad{
  planned_duration_min: 80,

  planned_sessions_by_type: %{
    six_count: 2,
    navy_seal: 2
  },

  planned_reps_by_type: %{
    six_count: integer(),
    navy_seal: integer()
  },

  planned_fatigue_units: float()
}
```

---

# 5. StyleRecommender — Bayesian

## Question

Given the current session context, which workout style is most likely to produce a successful workout?

## Style vocabulary

Use `:unbroken`, not `:burst`.

Recommended style arms:

```elixir
[
  :steady_sets,
  :unbroken,
  :front_loaded,
  :back_loaded,
  :interval,
  :ladder,
  :density
]
```

## Style meanings

```txt
:unbroken
  Continuous work with no planned rest.
  The athlete may naturally slow down, but the plan does not prescribe rest.

:steady_sets
  Repeated sets of similar size with consistent rests.

:front_loaded
  Larger sets or faster pace earlier, tapering later.

:back_loaded
  Easier start, stronger finish.

:interval
  Timed work/rest intervals.

:ladder
  Set sizes rise or fall predictably.

:density
  Max sustainable work inside a fixed time box.
```

## Inputs

```elixir
%{
  burpee_type: :six_count | :navy_seal,
  mood: -1 | 0 | 1,
  level: Level.t(),
  time_of_day_bucket: :morning | :afternoon | :evening | :night,

  recent_sessions: [WorkoutSession.t()],
  style_performances: [StylePerformance.t()],

  progression_rec: ProgressionRecommendation.t()
}
```

## Outputs

```elixir
[
  %StyleSuggestion{
    style_name: atom(),
    score: float(),
    session_count: integer(),
    confidence: :low | :medium | :high,
    rationale: String.t()
  }
]
```

## Bayesian scoring

Suggested success score:

```txt
success_score =
  0.50 * completion_ratio
+ 0.20 * pace_adherence
+ 0.15 * rest_adherence
+ 0.15 * subjective_rating_normalized
```

If no subjective rating exists, redistribute that weight across available metrics.

Context bucket:

```txt
{
  style_name,
  burpee_type,
  mood,
  level,
  time_of_day_bucket
}
```

The prior should dominate when `session_count` is small.

## Responsibilities

StyleRecommender decides:

```txt
ranked workout style archetypes
confidence
rationale
```

StyleRecommender does not decide:

```txt
sets
rests
pace
exact plan
weekly schedule
rep target
```

---

# 6. StyleConstraintMapper — deterministic

## Question

Given a selected style, level, burpee type, duration target, and intensity, what PlanSolver constraints should be used?

## Inputs

```elixir
%{
  style_name: atom(),
  level: Level.t(),
  burpee_type: :six_count | :navy_seal,
  duration_target_min: 20,
  target_intensity: :easy | :moderate | :hard
}
```

## Outputs

```elixir
%PlanConstraints{
  style_name: atom(),

  planned_rest_allowed?: boolean(),

  set_size_min: integer() | nil,
  set_size_max: integer() | nil,

  rest_sec_min: integer(),
  rest_sec_max: integer(),

  pace_sec_min: float(),
  pace_sec_max: float(),

  block_count_min: integer(),
  block_count_max: integer(),

  allow_variable_sets?: boolean(),
  allow_variable_pace?: boolean(),
  allow_long_rest_blocks?: boolean(),

  front_load_bias: float(),
  back_load_bias: float(),
  density_bias: float(),

  simplicity_weight: float(),
  style_adherence_weight: float()
}
```

## Burpee-type-specific set bounds

Set-size bounds must differ by burpee type.

Example defaults:

```elixir
case burpee_type do
  :six_count ->
    %{
      set_size_min: 8,
      set_size_max: 25
    }

  :navy_seal ->
    %{
      set_size_min: 2,
      set_size_max: 10
    }
end
```

These are example shapes and should be level-adjusted.

## `:unbroken`

```elixir
%PlanConstraints{
  style_name: :unbroken,

  planned_rest_allowed?: false,

  set_size_min: nil,
  set_size_max: nil,

  rest_sec_min: 0,
  rest_sec_max: 0,

  allow_variable_sets?: false,
  allow_variable_pace?: true,

  block_count_min: 1,
  block_count_max: 1,

  simplicity_weight: 1.0,
  style_adherence_weight: 1.5
}
```

For `:unbroken`, PlanSolver should produce one continuous 20-minute work block.

## `:steady_sets`

```elixir
%PlanConstraints{
  style_name: :steady_sets,

  planned_rest_allowed?: true,

  set_size_min: type_adjusted_min,
  set_size_max: type_adjusted_max,

  rest_sec_min: 15,
  rest_sec_max: 75,

  allow_variable_sets?: false,
  allow_variable_pace?: false,

  block_count_min: 1,
  block_count_max: 8,

  simplicity_weight: 1.2,
  style_adherence_weight: 1.0
}
```

## `:front_loaded`

```elixir
%PlanConstraints{
  style_name: :front_loaded,

  planned_rest_allowed?: true,

  set_size_min: type_adjusted_min,
  set_size_max: type_adjusted_max,

  rest_sec_min: 20,
  rest_sec_max: 90,

  allow_variable_sets?: true,
  allow_variable_pace?: true,

  front_load_bias: 1.0,
  back_load_bias: 0.0,

  simplicity_weight: 0.8,
  style_adherence_weight: 1.2
}
```

## Responsibilities

StyleConstraintMapper decides:

```txt
how style maps to feasible PlanSolver constraints
```

It does not:

```txt
rank styles
learn from data
optimize a plan
schedule workouts
```

---

# 7. PlanSolver — MILP

## Question

Given a single 20-minute planned session, how should the workout be structured?

## Timescale

One session.

## Domain

Mixed-integer linear optimization of session structure.

## Required modes

PlanSolver must support:

```elixir
:fixed_duration
:fixed_reps
```

## Default mode: fixed duration

The default mode for the app is `:fixed_duration`.

```elixir
%{
  mode: :fixed_duration,

  duration_target_min: 20,

  burpee_type: :six_count | :navy_seal,
  level: Level.t(),
  selected_style: atom(),
  target_intensity: :easy | :moderate | :hard,

  constraints: PlanConstraints.t(),

  user_preferences: %{
    prefer_round_numbers?: boolean(),
    max_plan_complexity: :low | :medium | :high
  }
}
```

In fixed-duration mode, PlanSolver chooses:

```txt
estimated achievable reps
pace
sets
rests
blocks
```

Subject to:

```txt
duration = 20 minutes
pace within level/type/intensity ceiling
style constraints
fatigue constraints
simplicity constraints
```

## Fixed reps mode

Use only when the user or ScheduleSolver provides a required rep target.

```elixir
%{
  mode: :fixed_reps,

  burpee_count_target: integer(),
  duration_target_min: 20,

  burpee_type: :six_count | :navy_seal,
  level: Level.t(),
  selected_style: atom(),
  target_intensity: :easy | :moderate | :hard,

  constraints: PlanConstraints.t()
}
```

If infeasible:

```elixir
{:error, :infeasible,
 %{
   reason: :rep_target_too_high_for_duration_and_level,
   suggested_rep_target: integer(),
   suggested_duration_min: integer()
 }}
```

## Outputs

```elixir
%WorkoutPlan{
  mode: :fixed_duration | :fixed_reps,

  duration_target_min: 20,

  burpee_count_target: integer(),
  burpee_type: :six_count | :navy_seal,
  style_name: atom(),

  estimated_duration_sec: integer(),

  sec_per_burpee: float(),

  sets: [
    %WorkoutSet{
      index: integer(),
      reps: integer(),
      sec_per_burpee: float(),
      rest_sec_after_set: integer()
    }
  ],

  blocks: [
    %WorkoutBlock{
      index: integer(),
      sets: [WorkoutSet.t()],
      rest_sec_after_block: integer()
    }
  ],

  planned_fatigue_units: float(),

  plan_difficulty_score: float(),
  plan_complexity_score: float()
}
```

## MILP decision variables

```txt
set_reps[i] ∈ Z≥0
  Number of reps in set i.

set_active[i] ∈ {0,1}
  Whether set i is used.

rest_after_set[i] ∈ Z≥0
  Rest seconds after set i.

pace_bucket[i, p] ∈ {0,1}
  Whether set i uses pace bucket p.

block_active[j] ∈ {0,1}
  Whether block j is used.

set_in_block[i, j] ∈ {0,1}
  Whether set i belongs to block j.

long_rest_after_block[j] ∈ Z≥0
  Longer rest after block j.

style_violation[k] ≥ 0
  Slack variables for soft style constraints.

duration_error_pos ≥ 0
duration_error_neg ≥ 0
  Deviation from target duration.

complexity_score ≥ 0
  Penalty for unnecessarily complex plans.
```

## Derived expressions

```txt
work_time =
  Σ_i set_reps[i] * sec_per_burpee[i]

set_rest_time =
  Σ_i rest_after_set[i]

block_rest_time =
  Σ_j long_rest_after_block[j]

estimated_duration_sec =
  work_time + set_rest_time + block_rest_time

total_reps =
  Σ_i set_reps[i]

planned_fatigue_units =
  total_reps * fatigue_units_per_rep[burpee_type]
```

## Hard constraints

```txt
estimated_duration_sec = 20 minutes, within tolerance

Each active set must satisfy type-adjusted and level-adjusted set-size bounds.

Inactive sets must have:
  set_reps[i] = 0
  rest_after_set[i] = 0

If planned_rest_allowed? is true:
  rest after active non-final sets must satisfy rest bounds.

If planned_rest_allowed? is false:
  all rests must be 0.

Pace must stay within level + burpee_type + intensity sustainable ceiling.

Final set has no planned rest after it.

Block count must stay within block_count_min and block_count_max.

If allow_variable_sets? is false:
  active sets should have equal or near-equal reps.

If allow_variable_pace? is false:
  active sets should use the same pace bucket.

If selected_style = :unbroken:
  exactly one continuous work block
  no planned rests
  no prescribed sets unless needed as display-only milestones
```

## Pace ceiling rules

```txt
easy:
  pace must be >= comfortable_sec_per_rep

moderate:
  pace must be >= challenging_sec_per_rep

hard:
  pace must be >= aggressive_sec_per_rep
```

Lower seconds per rep means faster and harder.

## Fixed-duration objective

In fixed-duration mode, minimize:

```txt
unused_time_penalty
+ inappropriate_pace_penalty
+ excessive_fatigue_penalty
+ style_violation_penalty
+ complexity_penalty
+ awkward_set_structure_penalty
+ excessive_pace_variation_penalty
```

Equivalent interpretation:

```txt
maximize productive work inside 20 minutes
while staying appropriate for level, burpee type, style, and intensity
```

## Fixed-reps objective

In fixed-reps mode, minimize:

```txt
duration_deviation_penalty
+ pace_difficulty_penalty
+ insufficient_rest_penalty
+ excessive_rest_penalty
+ style_violation_penalty
+ complexity_penalty
+ non_round_number_penalty
+ excessive_set_count_penalty
+ excessive_pace_variation_penalty
```

## Simplicity objective

Reward:

```txt
repeated set sizes
round rest values such as 15s, 20s, 30s, 45s, 60s
consistent pace
small number of block types
low number of instructions
```

Penalize:

```txt
many unique set sizes
awkward rests such as 23s or 37s
frequent pace changes
too many blocks
mathematically valid but hard-to-follow plans
```

## Responsibilities

PlanSolver decides:

```txt
estimated reps for a 20-minute session
set size
set count
pace
rest after each set
block structure
estimated duration
difficulty score
complexity score
planned fatigue units
```

PlanSolver does not decide:

```txt
weekly schedule
weekly type split
best style archetype
long-term progression
```

---

# 8. SessionAnalyzer — feedback normalization

## Question

After a workout is saved, what happened and what normalized learning signals should update the rest of the system?

## Inputs

```elixir
%{
  workout_session: WorkoutSession.t(),
  planned_workout: WorkoutPlan.t()
}
```

## Outputs

```elixir
%SessionAnalysis{
  workout_session_id: integer(),

  burpee_type: :six_count | :navy_seal,

  planned_duration_sec: integer(),
  actual_duration_sec: integer(),

  planned_reps: integer(),
  actual_reps: integer(),

  planned_sec_per_burpee: float(),
  actual_sec_per_burpee: float() | nil,

  planned_fatigue_units: float(),
  actual_fatigue_units: float(),

  completion_ratio: float(),

  planned_rate_per_min: float(),
  actual_rate_per_min: float(),
  rate_delta: float(),

  pace_adherence: float(),
  rest_adherence: float(),

  style_name: atom(),
  target_intensity: :easy | :moderate | :hard,

  plan_difficulty_score: float(),
  plan_complexity_score: float(),

  time_of_day_bucket: :morning | :afternoon | :evening | :night,
  level: Level.t(),
  mood: -1 | 0 | 1 | nil,

  subjective_rating: integer() | nil,
  failed_at_rep: integer() | nil,
  skipped?: boolean()
}
```

## Downstream updates

```txt
SessionAnalysis
  ├── Progression
  │     uses actual_rate_per_min, rate_delta, completion_ratio,
  │     and actual_fatigue_units
  │
  ├── StylePerformance
  │     uses style_name, mood, level, time_of_day_bucket,
  │     burpee_type, completion_ratio, pace_adherence, rest_adherence
  │
  ├── ScheduleSolver coefficients
  │     uses adherence by day/time/type/level
  │
  └── Personal pace ceiling
        future:
        learns sustainable pace by level and burpee type
```

## Responsibilities

SessionAnalyzer computes normalized facts.

It does not:

```txt
optimize
recommend
schedule
plan
```

---

# 9. Full system flow

```txt
Goal + availability + history
        │
        ▼
ScheduleSolver, MILP
        │
        │ outputs:
        │   4 × 20-minute sessions
        │   2 six-count
        │   2 navy-seal
        │   date
        │   time bucket
        │   target intensity
        │   estimated rep target
        ▼
User opens planned session
        │
        ▼
StyleRecommender, Bayesian
        │
        │ outputs:
        │   ranked style suggestions
        ▼
User or app selects style
        │
        ▼
StyleConstraintMapper
        │
        │ outputs:
        │   PlanConstraints
        ▼
PlanSolver, MILP
        │
        │ outputs:
        │   executable 20-minute WorkoutPlan
        ▼
PlannerLive
        │
        ▼
SessionLive
        │
        ▼
WorkoutSession saved
        │
        ▼
SessionAnalyzer
        │
        ▼
Progression + StylePerformance + Schedule coefficients
```

---

# 10. Separation of concerns

```txt
System                  Type          Owns
────────────────────────────────────────────────────────────
ScheduleSolver          MILP          weekly schedule, 4×20 structure,
                                      2+2 type split, timing, intensity,
                                      fatigue-adjusted load

StyleRecommender        Bayesian      style ranking and confidence

StyleConstraintMapper   Rules         style-to-constraint translation

PlanSolver              MILP          20-minute session structure:
                                      reps, sets, pace, rests, blocks

SessionAnalyzer         Rules         derived feedback metrics
```

---

# 11. Learning signals

```txt
System                  Learning signal
────────────────────────────────────────────────────────────
ScheduleSolver          adherence coefficients,
                        progression trend,
                        actual fatigue units,
                        actual rate per minute

StyleRecommender        completion_ratio,
                        pace_adherence,
                        rest_adherence,
                        subjective rating,
                        grouped by burpee_type/context

PlanSolver              none in v1;
                        future: personalized pace ceiling
                        by level and burpee type

SessionAnalyzer         none;
                        computes normalized metrics only
```

---

# 12. MPC property

The complete system behaves like a Model Predictive Control loop.

```txt
State:
  level
  progression trend
  recent sessions
  StylePerformance scores
  adherence coefficients
  personal pace ceilings
  recent fatigue-adjusted load

Model:
  progression model
  Bayesian style scores
  type-specific pace ceilings
  fatigue costs
  adherence estimates

Control:
  this week’s four 20-minute sessions

Plant:
  the user performing workouts

Horizon:
  weeks remaining until goal.date_target,
  or rolling training horizon if no date target exists
```

Every planning cycle:

```txt
1. ScheduleSolver plans over the rolling horizon.
2. Only the current week is committed.
3. The current week contains up to four 20-minute sessions.
4. The preferred composition is two six-count and two navy-seal sessions.
5. User performs sessions.
6. SessionAnalyzer computes outcomes.
7. Progression, StylePerformance, fatigue estimates, and adherence coefficients update.
8. Next planning cycle re-solves with fresh state.
```

Future weeks should be displayed as projections only, not as a fixed calendar.

---

# 13. Implementation invariants

```txt
ScheduleSolver must not generate sets.

ScheduleSolver must use fatigue-adjusted load when mixing burpee types.

ScheduleSolver should prefer 2 six-count + 2 navy-seal sessions per week.

ScheduleSolver must not schedule more than 2 navy-seal sessions per week
unless explicitly requested.

PlanSolver must not change the weekly type split.

PlanSolver must respect burpee-type-specific pace ceilings.

PlanSolver must support fixed-duration mode as the default.

StyleRecommender must not build concrete plans.

StyleConstraintMapper must not learn from data.

SessionAnalyzer must not make recommendations.
```

---

# 14. Best one-line architecture summary

ScheduleSolver uses MILP to allocate four 20-minute weekly sessions, preferably split into two six-count and two navy-seal workouts; StyleRecommender chooses the best workout archetype; StyleConstraintMapper converts that archetype into constraints; PlanSolver uses MILP to fill each 20-minute session with an executable structure; SessionAnalyzer turns completed workouts into normalized learning signals.
