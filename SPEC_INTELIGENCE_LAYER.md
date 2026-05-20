# Intelligence Layer Domain Spec

A conceptual map of the three intelligent subsystems in BurpeeTrainer,
what problem each solves, and how they are connected.

---

## The three problems

```
1. What should my week look like to reach my goal?
   → ScheduleSolver (MILP)

2. How should I structure today's session?
   → PlanSolver (MILP)

3. What style of workout works best for me right now?
   → StyleRecommender (Bayesian)
```

These are genuinely separate problems operating at different timescales
and answering different kinds of questions. None of them can replace the others.

---

## Problem 1 — ScheduleSolver (MILP)

**Question:** Given my goal, my history, and my available days — what should
I do this week, and how does that fit into the weeks ahead?

**Timescale:** weeks to months

**Domain:** combinatorial scheduling over time

**Inputs:**
```
goal.burpee_count_target    what I am trying to achieve
goal.date_target            by when
sessions (recent history)   what I have actually done
available_days              which days I can train
level                       current capacity
StylePerformance            which time-of-day slots work best
```

**Outputs:**
```
For each week in the horizon:
  which days to train
  which burpee type per day
  how many reps per day
  recommended time-of-day slot
```

**Why MILP:**
The constraints interact across time. Recovery gaps couple adjacent days.
Periodization couples adjacent weeks. Volume progression couples all weeks
to the goal date. The optimal tradeoff between these cannot be found by
a greedy algorithm — small decisions early in the horizon compound and
the solver needs to see the full picture.

**What it does NOT decide:**
How to structure a session (sets, pace, rest). That is PlanSolver's domain.

---

## Problem 2 — PlanSolver (MILP)

**Question:** Given I am doing N reps today — what pace, set size, and rest
structure is optimal for my current level?

**Timescale:** one session

**Domain:** continuous/integer optimization of session structure

**Inputs:**
```
burpee_count_target    how many reps total (from ScheduleSolver or user)
burpee_type            six_count | navy_seal
target_duration_min    how long the session should be
pacing_style           even | unbroken
additional_rests       optional mid-session rest points
level                  determines sustainable pace ceiling
```

**Outputs:**
```
sec_per_burpee         optimal pace (solver-chosen, not user-inputted)
set_size               reps per set
set_count              number of sets
rest_sec_after_set     rest between sets
blocks / sets          fully structured WorkoutPlan
```

**Why MILP:**
Two objectives genuinely conflict:
- Slower pace → more sustainable, less burnout
- More rest → better recovery between sets
- Both consume the time budget, so maximizing one reduces the other

A heuristic would hardcode a priority. The MILP finds the Pareto-optimal
tradeoff for the specific rep count, duration, and level combination.
The sustainable ceiling per level is the key constraint — it prevents
the solver from choosing a pace that is mathematically optimal but
physically unsustainable for where the user actually is.

**What it does NOT decide:**
Which style of workout (burst, even, front-loaded etc). That is
StyleRecommender's domain. PlanSolver takes style as a constraint
(via `pacing_style` and `additional_rests`) but does not choose it.

---

## Problem 3 — StyleRecommender (Bayesian)

**Question:** Given my current context — what kind of workout structure
has worked best for me?

**Timescale:** per session, learned over months

**Domain:** contextual multi-armed bandit (approximated with Bayesian scoring)

**Inputs:**
```
burpee_type            six_count | navy_seal
mood                   -1 | 0 | 1  (tired / ok / hyped)
level                  current level
time_of_day_bucket     morning | afternoon | evening | night
sessions               recent history
performances           StylePerformance records (the learning signal)
progression_rec        current Progression recommendation
```

**Outputs:**
```
Top 3 StyleSuggestions, each containing:
  style_name           e.g. :burst, :even, :front_loaded
  score                Bayesian score for this context bucket
  session_count        how many sessions inform this score
  rationale            human-readable explanation
  plan                 pre-generated WorkoutPlan via StyleGenerator
```

**Why Bayesian:**
This is a learning problem, not an optimization problem. There is no
closed-form answer to "what style works best for me" — it depends on
personal physiology, training history, and context that cannot be
specified upfront. The Bayesian scorer starts with a prior (all styles
equally good) and updates toward the user's actual performance data
as sessions accumulate. With small data the prior dominates; with
enough data the user's true pattern emerges.

**What it does NOT decide:**
When to train, how many reps, or how to structure the session.
StyleRecommender outputs a style preference — PlanSolver turns that
into concrete structure.

---

## How they connect

```
                        GOAL
                          │
                          ▼
              ┌─── ScheduleSolver (MILP) ───┐
              │   macro: weeks → goal        │
              │                              │
              │   "Mon: 108 six-counts,      │
              │    morning, level 1C"        │
              └──────────────┬───────────────┘
                             │
                    user taps session card
                             │
                             ▼
              ┌─── StyleRecommender (Bayesian) ───┐
              │   "burst works best for you       │
              │    on Monday mornings at level 1C" │
              └──────────────┬────────────────────┘
                             │
                    style feeds into pacing_style
                             │
                             ▼
              ┌─── PlanSolver (MILP) ───────┐
              │   micro: session structure   │
              │                              │
              │   inputs:                    │
              │     reps=108, type=six_count │
              │     level=1C, pacing=even    │
              │     duration=20min           │
              │                              │
              │   outputs:                   │
              │     pace=5.8s/rep            │
              │     set_size=9               │
              │     rest=28s                 │
              └──────────────┬───────────────┘
                             │
                             ▼
                      PlannerLive
                   (user reviews, confirms)
                             │
                             ▼
                       SessionLive
                    (client-side execution)
                             │
                             ▼
                      WorkoutSession saved
                      (derived fields computed)
                             │
                    ┌────────┴────────┐
                    ▼                 ▼
            StylePerformance    Progression trend
            upserted            updated
                    │                 │
                    ▼                 ▼
            StyleRecommender    ScheduleSolver
            learns from it      re-solves next Monday
```

---

## Data flows between the three systems

### ScheduleSolver → PlanSolver

```
ScheduleSolver output:
  burpee_count_target: 108
  burpee_type:         :six_count
  time_of_day_bucket:  :morning    ← recommended slot

These become PlanSolver inputs directly.
The user's standard session duration (e.g. 20 min) fills target_duration_min.
```

### StyleRecommender → PlanSolver

```
StyleRecommender output:
  style_name: :burst

:burst maps to pacing constraints in PlanSolver:
  pacing_style:    :even
  set_size_min:    4      ← burst = small clusters
  set_size_max:    6
  rest_sec_min:    5      ← short micro-rest within cluster
```

StyleRecommender does not call PlanSolver directly. It passes style
as a constraint that shapes the PlanSolver's feasible region.

### WorkoutSession → all three systems

Every saved session feeds back into all three systems:

```
WorkoutSession saved
  │
  ├── rate_per_min_actual, rate_delta
  │   → Progression.project_trend/1
  │   → ScheduleSolver re-solve: updated capacity estimate
  │
  ├── completion_ratio (actual/planned)
  │   → StylePerformance upserted for (style, mood, level, time_of_day)
  │   → StyleRecommender: Bayesian score updated for this context bucket
  │
  └── time_of_day_bucket, completion_ratio
      → ScheduleSolver: time_of_day_penalty coefficients updated
        (bad evening completion → solver schedules fewer evening sessions)
```

---

## Separation of concerns

Each system has one owner and one learning signal:

```
System              Owner module          Learning signal
──────────────────────────────────────────────────────────
ScheduleSolver      BurpeeTrainer.        rate_per_min_actual
                    ScheduleSolver        (trend via Progression)

PlanSolver          BurpeeTrainer.        sustainable_ceiling
                    PlanSolver            (hardcoded per level,
                                          future: learned from
                                          completion_ratio vs pace)

StyleRecommender    BurpeeTrainer.        completion_ratio per
                    StyleRecommender      (style, mood, level,
                                          time_of_day_bucket)
```

PlanSolver is the only system that does not yet learn from data —
its sustainable ceiling is hardcoded per level. The natural v3 upgrade
is to learn the ceiling from actual session data: if a level_1c user
consistently completes sessions at 5.2s/rep, the solver updates their
personal ceiling from 6.0 to 5.2. This requires storing `sec_per_burpee`
on `WorkoutSession` (it is already there via the plan) and computing
a rolling average per level.

---

## MPC property

The full system is a Model Predictive Control loop:

```
State:    level, trend, StylePerformance scores, recent sessions
Model:    Progression linear trend, Bayesian style scores, level ceilings
Control:  this week's session schedule (ScheduleSolver output)
Plant:    the user doing burpees
Horizon:  weeks remaining to goal.date_target (receding)
```

Every Monday the solver re-runs with fresh state. The horizon shortens
by one week. The control action (this week's sessions) is executed.
The outcome is observed and fed back. The model updates. Repeat.

The key MPC property: only the current week is a commitment. The rest
of the horizon is the solver's current best guess and changes every
re-solve. Showing the user a fixed 12-week calendar would be misleading —
the system shows current week in detail, future weeks as a projected
volume sparkline only.
