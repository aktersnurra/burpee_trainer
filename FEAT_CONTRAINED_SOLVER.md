# SPEC: Constraint Solver Architecture (Unified Planning Engine)

## 1. Overview

This system replaces procedural workout planning logic with a **unified constraint solver pipeline**.

It supports:

* Even pacing
* Unbroken pacing
* Rest distribution
* Rest placement

All handled via:

* Variables
* Constraints (hard + soft)
* Deterministic + discrete solvers

---

## 2. Core Idea

Everything becomes:

```elixir
plan
|> extract_variables()
|> add_constraints(input)
|> solve()
|> apply()
```

No special cases for:

* even vs unbroken
* rest fitting vs placement

---

## 3. Variables

```elixir
%{
  rests: [
    %{id: {block, set}, value: float, original: float, weight: integer}
  ],

  placements: [
    %{
      id: integer,
      target_sec: float,
      candidates: [integer],
      index: integer | nil,
      actual_sec: float | nil
    }
  ],

  base_duration_sec: float,
  target_rest_total: float | nil
}
```

---

## 4. Constraints

### Hard

* total duration
* rest ≥ 0
* placement must exist

### Soft

* minimize rest deviation
* minimize placement error

---

## 5. Solver Pipeline

```elixir
vars
|> solve_continuous()
|> solve_discrete()
|> evaluate_constraints()
```

---

## 6. Continuous Solver (Rest Scaling)

Closed-form:

```elixir
scale = target_rest_total / current_rest_total
```

Fallback:

```elixir
uniform distribution
```

---

## 7. Discrete Solver (Placement)

### Step 1: Greedy

```elixir
pick nearest boundary
```

### Step 2 (optional): Conflict Resolution

If multiple placements want same boundary:

Use DP/backtracking:

```elixir
minimize Σ |actual - target|
subject to unique boundary usage
```

---

## 8. Even vs Unbroken (Unified)

Both become the same system:

### Even

* single large set
* cadence variable
* placements on rep boundaries

### Unbroken

* multiple sets
* rests already explicit
* placements on set boundaries

Difference is only:

```elixir
boundaries = rep_boundaries | set_boundaries
```

---

## 9. ConstraintSolver Module

```elixir
def solve(plan, constraints, opts \\ []) do
  vars = Extract.variables_from_plan(plan)
  vars = inject_targets(vars, opts)

  vars = solve_continuous(vars)
  vars = solve_discrete(vars, opts)

  solution = evaluate(constraints, vars)

  apply_solution(plan, solution)
end
```

---

## 10. Conflict Solver (DP)

```elixir
assign placements → boundaries
minimize cost
avoid duplicates
```

Used only when needed.

---

## 11. Integration Strategy

Replace:

* fit_rest_to_duration
* rest placement logic

With:

```elixir
ConstraintSolver.solve(plan, constraints, opts)
```

---

## 12. What This Enables

* Add fatigue models easily
* Add user preferences (soft constraints)
* Combine pacing styles
* Multi-objective optimization

---

## 13. Mental Model

You are no longer “building a workout” procedurally.

You are:

> Solving for variables under constraints to produce a valid, optimized plan.

Key shifts:

* Logic → declarations
* Steps → constraints
* Special-cases → data

---

## 14. Defaults & Conventions

* Time unit: seconds (float during solve, rounded on apply)
* All rests ≥ 0
* Final set rest = 0 (enforced outside or as constraint)
* Tolerance defaults:

  * duration: ±1s
  * placement: ±30s

---

## 15. Boundaries Abstraction

Unify “even” and “unbroken” via boundaries.

```elixir
@type boundary :: %{index: integer, time_sec: float}
```

Producers:

* `rep_boundaries(plan)` for even pacing
* `set_boundaries(plan)` for unbroken

The solver only sees `boundaries :: [boundary]`.

---

## 16. Variable Extraction (Recap)

```elixir
vars = %{
  rests: [%{id: {b, s}, value: float, original: float, weight: integer}],
  placements: [%{id: i, target_sec: float, candidates: [integer], index: nil, actual_sec: nil}],
  base_duration_sec: float,
  target_rest_total: float | nil
}
```

---

## 17. Continuous Solve (Rest Scaling)

Closed-form (preferred):

```elixir
scale = target_rest_total / current_rest_total
```

Edge case (all rests zero):

```elixir
per_slot = target_rest_total / total_slots
```

Always clamp:

```elixir
value = max(value, 0.0)
```

---

## 18. Discrete Solve (Placement)

### Greedy (default)

```elixir
for each placement:
  choose candidate with minimal |boundary.time - target_sec|
```

### When to upgrade

Upgrade to global solver if:

* multiple placements map to same boundary
* strict uniqueness required

---

## 19. Global Assignment (Conflict Resolution)

Formulation:

* placements P
* boundaries B
* cost c(i,j) = |B[j].time - target_i|

Goal:

```text
minimize Σ c(i, assign(i))
subject to unique boundary usage
```

Implementation options:

* Backtracking (N ≤ 10)
* Hungarian algorithm (future)

---

## 20. Constraint Evaluation

Order:

1. Hard constraints → must pass
2. Soft constraints → accumulate penalty

```elixir
objective = Σ penalties
feasible? = all hard constraints satisfied
```

Return on failure:

```elixir
{:error, %{type: :infeasible, constraint: atom, info: map}}
```

---

## 21. Apply Solution

* Round rests to integers
* Write back to sets via `{block.position, set.position}` keys
* Leave non-modeled fields unchanged

---

## 22. End-to-End Flow

```elixir
boundaries = build_boundaries(plan, style)

placements = Placement.build_candidates(boundaries, targets, 30.0)

constraints = [
  TotalDuration.build(target_sec, 1.0),
  RestNonNegative.build(),
  MinimizeRestDeviation.build(),
  ValidPlacement.build(),
  MinimizePlacementError.build()
]

{:ok, new_plan} =
  ConstraintSolver.solve(
    plan,
    constraints,
    target_rest_total: computed_value,
    boundaries: boundaries,
    placements: placements
  )
```

---

## 23. Migration Plan

1. Replace `fit_rest_to_duration/2` with solver (continuous only)
2. Replace placement logic with greedy solver
3. Add optional assignment solver behind flag
4. Delete legacy branching (even vs unbroken differences)

---

## 24. Testing Strategy

* Unit: each constraint module
* Property:

  * total duration within tolerance
  * no negative rests
* Scenario:

  * even with rests
  * unbroken with additional rests
* Regression: snapshot timelines

---

## 25. Extensibility Hooks

* Fatigue curve: make `sec_per_rep` a variable with slope constraint
* User preference: add soft constraints with weights
* Multi-objective: weighted penalties

---

## 26. Performance Notes

* Continuous solve: O(n)
* Greedy placement: O(n * k)
* Backtracking (worst): O(k^n) but small n in practice

Guardrails:

* cap placements (≤ 5 typical)
* early pruning in DP

---

## 27. Summary

A single, unified system now handles:

* Duration fitting
* Rest distribution
* Rest placement
* Even + unbroken pacing

All via:

> Variables + Constraints + Solvers

---
