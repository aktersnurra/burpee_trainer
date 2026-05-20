# MILP Solvers Patch

Apply on top of SPEC.md. Covers two MILP modules operating at different
levels of abstraction. Replaces PlanWizard entirely.

---

## Overview

```
ScheduleSolver (macro — weeks to goal)
  inputs:  goal, history, available_days, level
  outputs: which days, which type, how many reps, time of day

       ↓  feeds burpee_count_target + burpee_type + level

PlanSolver (micro — one session)
  inputs:  total_reps, burpee_type, pacing, level, target_duration, additional_rests
  outputs: set_size, set_count, sec_per_burpee, rest_sec_after_set, blocks
```

`sec_per_burpee` is removed as a user input entirely. The PlanSolver
finds the optimal pace given the user's level. Users never guess a pace.

---

## PlanSolver — BurpeeTrainer.PlanSolver

Replaces `BurpeeTrainer.PlanWizard`. Pure Elixir module, no Ecto dependency.
Wraps HiGHS (same dependency as ScheduleSolver).

### Removed input
```
sec_per_burpee   -- REMOVED from PlanInput and from Layer 1 UI
```

### Updated input struct
```elixir
%PlanInput{
  name,
  burpee_type,              -- :six_count | :navy_seal
  target_duration_min,      -- int: target duration (validated ±5s on save)
  burpee_count_target,      -- int: exact total reps
  pacing_style,             -- :even | :unbroken
  additional_rests,         -- [%{rest_sec: int, target_min: int}] (even only)
  level,                    -- level_atom: used for sustainable ceiling
}
```

### Variables
```
sec_per_burpee  ∈ ℝ     continuous: pace per rep
set_size        ∈ ℤ+    integer: reps per set
set_count       ∈ ℤ+    integer: number of sets
rest_sec        ∈ ℝ     continuous: rest after each set
```

### Hard constraints
```
# Total reps (exact)
set_size * set_count = burpee_count_target

# Duration (±5s)
set_size * sec_per_burpee * set_count + rest_sec * set_count
  ∈ [target_duration_sec - 5, target_duration_sec + 5]

# Physical floor — absolute minimum pace (graduation standard)
sec_per_burpee >= sec_per_burpee_floor[burpee_type]

sec_per_burpee_floor = %{
  six_count:  Float.ceil(1200 / 325, 2),   # 3.70s
  navy_seal:  1200 / 150                   # 8.00s
}

# Sustainable ceiling — level-dependent max pace
sec_per_burpee >= sustainable_ceiling[level]

sustainable_ceiling = %{
  level_1a:  8.0,
  level_1b:  7.0,
  level_1c:  6.0,
  level_1d:  5.5,
  level_2:   5.0,
  level_3:   4.5,
  level_4:   4.0,
  graduated: 3.70
}

# Note: sec_per_burpee >= ceiling means pace is AT LEAST this slow.
# Solver will find the optimal pace between ceiling and what maximizes rest.
# A level_1c user will never get a 3.75s pace even if it "fits" mathematically.

# Minimum rest per set (style-dependent)
rest_sec >= min_rest[pacing_style]

min_rest = %{
  even:     10,    # always some recovery between sets
  unbroken: 0      # back to back, no rest
}
```

### Objective function
```
Minimize:
  α * pace_intensity_score
  - β * rest_sec

Where:
  pace_intensity_score = sec_per_burpee_floor[burpee_type] / sec_per_burpee
  # → 1.0 at physical floor (maximum intensity, unsustainable)
  # → 0.0 at very slow pace (minimum intensity, very sustainable)
  # Minimizing this pushes pace toward slower = more sustainable

Coefficients:
  @alpha 0.6   # weight: prefer sustainable pace
  @beta  0.4   # weight: prefer more rest per set
```

The solver trades off slower pace vs more rest. At graduation level
the floor and ceiling converge so the solver has less room — reflecting
the reality that elite performance requires higher intensity.

### Unbroken pacing

For `:unbroken`:
```
set_count = 1
set_size  = burpee_count_target
rest_sec  = 0
sec_per_burpee = target_duration_sec / burpee_count_target
               (derived directly, no optimization needed — just check ceiling)
```

If derived pace < sustainable_ceiling[level]: return `{:error, :pace_unsustainable}`.
Message: "#{burpee_count_target} reps in #{target_duration_min} min requires
          #{derived_pace}s/rep — minimum for your level is #{ceiling}s/rep."

### Additional rests

Same logic as before — nearest block boundary within 30s. No change.

### Output
```elixir
%PlanSolution{
  set_size:        integer,
  set_count:       integer,
  sec_per_burpee:  float,      # solver-chosen, shown in Layer 3
  rest_sec:        float,
  duration_sec:    float,      # derived, shown in Layer 3
  plan:            %WorkoutPlan{}
}
```

### Public API
```elixir
BurpeeTrainer.PlanSolver.solve/1
# %PlanInput{} -> {:ok, %PlanSolution{}} | {:error, reason}

BurpeeTrainer.PlanSolver.sustainable_ceiling/1
# level_atom -> float
# Exposed so UI can show "min pace for your level: 6.0s/rep"
```

### Save validation (unchanged)
```
1. sum(burpee_count from all sets) == burpee_count_target   (exact)
2. |derived_duration_sec - target_duration_min * 60| <= 5   (±5s)
3. sec_per_burpee >= sustainable_ceiling[level]             (hard)
```

### Tests (ExUnit)
Cover:
- Even pacing: total reps exact, duration within ±5s
- Solver chooses pace >= sustainable_ceiling for each level
- Solver never exceeds physical floor
- Higher level → faster optimal pace (lower sec_per_burpee)
- Unbroken: one set, derived pace, ceiling check
- Unbroken with pace below ceiling → :pace_unsustainable error
- additional_rests placement within 30s
- additional_rests with unbroken → error

---

## ScheduleSolver — BurpeeTrainer.ScheduleSolver

No change to variables or constraints from previous spec.

### Addition: time-of-day coefficients from StylePerformance

```elixir
# time_of_day_penalty[d] and performance_score[d]
# derived from StylePerformance records:
# days/buckets where avg_completion is low → higher penalty
# computed in build_time_of_day_coefficients/1 (pure, no I/O)

def build_time_of_day_coefficients(performances) do
  performances
  |> Enum.group_by(& &1.time_of_day_bucket)
  |> Map.new(fn {bucket, perfs} ->
    avg = Enum.sum(perfs, & &1.completion_ratio_sum / max(&1.session_count, 1)) / length(perfs)
    {bucket, 1.0 - avg}   # higher penalty for lower avg completion
  end)
end
```

### Addition: feeds level into PlanSolver

When a session card is tapped, `ScheduleSolver` output feeds into `PlanSolver`:

```elixir
# GoalsLive tap handler
def handle_event("start_session", %{"scheduled_session_id" => id}, socket) do
  session = Schedule.get_scheduled_session(id)
  level   = Levels.current_level(socket.assigns.sessions)

  {:ok, solution} = PlanSolver.solve(%PlanInput{
    burpee_count_target: session.target_reps,
    burpee_type:         session.burpee_type,
    target_duration_min: 20,          # user's standard session duration
    pacing_style:        :even,       # or from StyleRecommender
    level:               level,
    additional_rests:    []
  })

  # Open PlannerLive with solution pre-filled for review
  {:noreply, push_navigate(socket, to: ~p"/plans/new?from_solution=#{solution.id}")}
end
```

---

## UI changes

### Layer 1 — Basics (updated)

Remove `sec_per_burpee` field entirely.
Add level indicator (read-only, informational):

```
name
burpee_type       [6-Count] [Navy Seal]
target_duration   [20] min
total_reps        [108]
pacing            [Even] [Unbroken]

Your level: 1C  →  min pace: 6.0s/rep  (shown as hint, not editable)
```

### Layer 3 — Blocks (updated)

Solver output shown at top before block breakdown:

```
Solver chose:
  Pace:     5.8s / rep    ← found by solver, shown for transparency
  Set size: 9 reps
  Rest:     28s / set
  Duration: 19m 58s  ✓   (target: 20m ±5s)
  Burpees:  108  ✓        (required: 108)
```

User can still edit any field in the block editor below. Save re-validates.

### Pace shown but not inputted

`sec_per_burpee` appears in Layer 3 as a read-only solver output that becomes
editable if the user manually adjusts blocks. It is never a Layer 1 input.

---

## What is removed from SPEC.md

- `sec_per_burpee` from `PlanInput` / Layer 1 UI
- `BurpeeTrainer.PlanWizard` — renamed to `BurpeeTrainer.PlanSolver`
- `BurpeeTrainer.PlanWizard.validate_pace/2` — replaced by
  `BurpeeTrainer.PlanSolver.sustainable_ceiling/1`
- Hardcoded pace floor shown in Layer 1 UI — now shown as level-derived
  sustainable ceiling in Layer 1 hint and Layer 3 output

## What is renamed

```
BurpeeTrainer.PlanWizard  →  BurpeeTrainer.PlanSolver
%PlanInput{}              →  %PlanInput{}  (same name, sec_per_burpee removed)
%WorkoutPlan{} output     →  %PlanSolution{} (wraps %WorkoutPlan{} + metadata)
plan_wizard.ex            →  plan_solver.ex
```
