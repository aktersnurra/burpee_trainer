# MILP Plan Wizard — Design

**Date:** 2026-05-11
**Status:** Approved (pending user review)
**Scope:** Replace the bespoke constraint-solver pipeline in `BurpeeTrainer.PlanWizard` with a MILP formulation solved by HiGHS, and add a fatigue model to bias rest distribution toward later slots.

---

## 1. Motivation

The current `PlanWizard.Solver` is a closed-form proportional distribution with a greedy reservation placer and six imperative constraint modules. It works, but the logic is spread across many small modules and "adding a new constraint" requires writing a new behavior module. A declarative MILP model expresses the same semantics in one place, replaces the greedy reservation assignment with provably optimal assignment, and makes future constraints easy to add. A fatigue model is included as the first new constraint type to validate the new architecture.

This is a refactor for conceptual cleanliness, not raw line reduction. Expected change in total LOC is small.

## 2. Architecture

```
BurpeeTrainer.PlanWizard               (unchanged public API: generate/1)
├── PlanInput                          (unchanged + new fatigue_factor field)
├── SlotModel                          (unchanged)
├── Styles                             (unchanged)
├── Apply                              (unchanged)
├── Errors                             (unchanged)
├── Lp                                 NEW: builds %LpProblem{} from %SlotModel{}
├── Lp.Problem                         NEW: struct (vars, constraints, objective)
├── Mps                                NEW: serializes %LpProblem{} to MPS string
├── Highs                              NEW: invokes HiGHS CLI, parses solution
└── Solver                             REWRITTEN: orchestrates Lp → Mps → Highs
```

**Deleted:**
- `BurpeeTrainer.PlanWizard.Reservation`
- `BurpeeTrainer.PlanWizard.Constraints.MinimizePlacementError`
- `BurpeeTrainer.PlanWizard.Constraints.MinimizeRestDeviation`
- `BurpeeTrainer.PlanWizard.Constraints.RestNonNegative`
- `BurpeeTrainer.PlanWizard.Constraints.TotalDuration`
- `BurpeeTrainer.PlanWizard.Constraints.ValidPlacement`

**Retained:**
- `BurpeeTrainer.PlanWizard.Constraints.PaceFloor` (pre-LP feasibility gate)

**Solver pipeline:**
1. `PaceFloor.check_input/1` — pace floor, work fits in target, additional rests don't force cadence below floor
2. `SlotModel.new/2` — universal slot representation
3. `Lp.build/1` — construct `%LpProblem{}` from slot model
4. `Mps.serialize/1` — emit MPS string to a temp file
5. `Highs.solve/1` — invoke HiGHS, parse the solution file
6. Inject `r[i]` values into `slot_rests`, return `{:ok, model}`
7. `Apply.to_workout_plan/2` — collapse to `%WorkoutPlan{}` (unchanged)

The `:unbroken` degenerate one-set short-circuit in `PlanWizard.run_pipeline/2` is retained — no point invoking the LP for a workout with one set.

## 3. MILP Formulation

Let `N = burpee_count_target`, `S = sec_per_burpee`, `T = target_duration_min * 60`, `K = |additional_rests|`. Slots are 1-indexed: slot `i` is the gap between rep `i` and rep `i+1`.

### 3.1 Decision variables

| Variable | Type | Range | Meaning |
|---|---|---|---|
| `r[i]`, `i = 1..N-1` | continuous | `≥ 0` | rest seconds at slot `i` |
| `x[k,i]`, `k = 1..K`, `i ∈ AllowedSlots(k)` | binary | `{0,1}` | 1 iff reservation `k` is assigned to slot `i` |
| `y[k,i]`, same indices | continuous | `≥ 0` | linearization of `x[k,i] * slot_end_time[i]` |
| `d[k]`, `k = 1..K` | continuous | `≥ 0` | placement error magnitude for reservation `k` |
| `e[i]`, `i = 1..N-1` | continuous | `≥ 0` | absolute deviation of `r[i]` from `r_ideal[i]` |

`AllowedSlots(k)` is the set of slots `i` such that the projected wall-clock time at slot `i` is within ±30s of `target_min_k * 60`. Pruned upfront from the slot-time projection (same projection the current code uses for nearest-slot search), to keep the model small. For `:unbroken` style, `AllowedSlots(k)` is further restricted to set-boundary slots.

### 3.2 Hard constraints

1. **Total duration (equality):**
   `Σ_i r[i] = T - N * S`

2. **Zero-weight slots** (`:unbroken` only — intra-set slots are no-rest):
   For each `i` with `weight[i] = 0`: `r[i] = 0`

3. **Each reservation assigned to exactly one slot:**
   For each `k`: `Σ_i x[k,i] = 1`

4. **At most one reservation per slot:**
   For each `i`: `Σ_k x[k,i] ≤ 1`

5. **Reservation ordering** (`:even` only — preserves legacy `prev_split + 1` semantics):
   For reservations sorted by `target_min`, consecutive `k1, k2`:
   `Σ_i i * x[k1,i] + 1 ≤ Σ_i i * x[k2,i]`

6. **Rest amount at assigned slot** (big-M linkage):
   For each `k, i ∈ AllowedSlots(k)`:
   - `r[i] ≥ R_k - M * (1 - x[k,i])`
   - `r[i] ≤ R_k + M * (1 - x[k,i])`

   When `x[k,i] = 1`, forces `r[i] = R_k`. When `x[k,i] = 0`, vacuous. `M = T` (safe upper bound).

7. **Placement error linearization:**
   Let `slot_end_time[i] = i * S + Σ_{j≤i} r[j]` (linear expression in `r`).

   For each `k, i ∈ AllowedSlots(k)`:
   - `y[k,i] ≤ M * x[k,i]`
   - `y[k,i] ≤ slot_end_time[i]`
   - `y[k,i] ≥ slot_end_time[i] - M * (1 - x[k,i])`
   - `y[k,i] ≥ 0`

   Then `actual_k = Σ_i y[k,i]` (linear), and:
   - `d[k] ≥ actual_k - T_k` where `T_k = target_min_k * 60`
   - `d[k] ≥ T_k - actual_k`
   - `d[k] ≤ 30` (placement tolerance)

8. **Deviation linearization** (for objective's secondary term):
   For each `i`:
   - `e[i] ≥ r[i] - r_ideal[i]`
   - `e[i] ≥ r_ideal[i] - r[i]`

   `r_ideal[i]` is precomputed from fatigue-adjusted weights (see §4).

### 3.3 Objective

`minimize Σ_k d[k] + ε * Σ_i e[i]`

`ε` is a small constant (e.g., `1e-3`) chosen so the placement-error term dominates: HiGHS minimizes placement error first, then breaks ties by matching the fatigue-shaped ideal distribution. When `K = 0`, the first term is empty and the second term drives the solution to match the ideal distribution exactly.

### 3.4 Model size (typical)

For 100 reps with 2 reservations and 30s tolerance window (~6 candidate slots per reservation under `:even`):
- ~99 `r` + 99 `e` + 12 `x` + 12 `y` + 2 `d` = **~224 variables**
- ~12 binaries
- ~250 constraints

HiGHS solves problems of this size in milliseconds.

## 4. Fatigue Model

New field on `PlanInput` (and persisted on `WorkoutPlan`):

```elixir
fatigue_factor :: float    # range [0.0, 1.0], default 0.0
```

Effect on `r_ideal`:

```
base_weight[i]     = Styles.weight_vector(style, N, reps_per_set)[i]
fatigue_weight[i]  = 1 + fatigue_factor * (i / (N - 1))   # linear ramp 1 → 2
combined_weight[i] = base_weight[i] * fatigue_weight[i]
r_ideal[i]         = budget * combined_weight[i] / Σ combined_weight
```

- `fatigue_factor = 0.0` → `r_ideal` matches today's proportional distribution exactly (parity).
- `fatigue_factor = 1.0` → later slots get up to 2× the ideal rest of earlier slots.
- For `:unbroken`: zero-weight intra-set slots remain zero (hard constraint); only set-boundary slots see fatigue bias.

The fatigue model affects **only the soft objective term**. Hard constraints (total duration, reservations, zero-weight slots) are unchanged.

UI: three-stop slider in the plan edit form — None / Mild / Strong → 0.0 / 0.5 / 1.0. Default "None" preserves existing behavior for users who don't engage with it.

## 5. HiGHS Integration

### 5.1 MPS serialization

`BurpeeTrainer.PlanWizard.Mps.serialize/1` is a pure function emitting standard MPS format. Variable naming: `r_1..r_{N-1}`, `e_1..e_{N-1}`, `x_{k}_{i}`, `y_{k}_{i}`, `d_{k}`. Constraint naming follows `<purpose>_<index>` for diagnostic legibility.

Binary variables are wrapped in `MARKER 'INTORG'` / `MARKER 'INTEND'` blocks in the COLUMNS section, per MPS conventions.

### 5.2 Highs port

```elixir
@spec solve(LpProblem.t()) ::
        {:ok, %{r: [float], objective: float}}
        | {:error, :infeasible | :timeout | {:exit, integer, String.t()}}
```

Implementation:
1. Serialize problem to MPS string.
2. Write to a uniquely-named temp file under `System.tmp_dir!()`.
3. `System.cmd(highs_path, [mps_path, "--solution_file", sol_path, "--options_file", opts_path], stderr_to_stdout: true)`.
4. Parse the solution file for the `r` variable values and objective.
5. Clean up temp files in an `after` block.

**Options file** (`priv/highs_options.txt`):
```
presolve = on
time_limit = 5
mip_rel_gap = 1e-6
```

**Binary path:** configurable via `config :burpee_trainer, :highs_path`, default `"highs"`. Application start logs a warning if `System.find_executable("highs")` returns `nil` (does not crash — the solver is only needed during plan generation).

### 5.3 Error mapping

| HiGHS result | Action |
|---|---|
| Optimal | Extract `r[i]`, inject into `slot_rests`, return `{:ok, model}` |
| Infeasible, no reservations | Return existing total-duration error |
| Infeasible, reservations present | Inspect `d[k]` slack; map to `cannot_place_rest_out_of_tolerance_*` for the offending reservation. Fall back to a generic message if the slack inspection is inconclusive. |
| Unbounded | Raise — indicates a model-construction bug |
| Time limit hit | Return `{:error, :timeout}` (should never happen for problems this size — log and investigate) |
| Non-zero exit | Wrap stderr in `{:error, {:exit, code, stderr}}` |

## 6. Data Model Migration

- New migration: `add :fatigue_factor, :float, default: 0.0, null: false` on `workout_plans`.
- Schema change: add `:fatigue_factor` to `BurpeeTrainer.Workouts.WorkoutPlan`.
- Struct change: add `fatigue_factor` to `BurpeeTrainer.PlanWizard.PlanInput`, default `0.0`.
- Form change: `PlansLive.Edit` gains a three-stop slider/segmented control.

Existing plans default to `0.0` and are not touched. Plans are immutable once created — no re-generation of stored plans is needed.

## 7. Testing Strategy

**Property-based (pure modules):**
- `Lp.build/1`: structural invariants on any valid `SlotModel` — variable cardinality, unique names, one assignment row per reservation, zero-rest row per zero-weight slot.
- `Mps.serialize/1`: round-trip equivalence (parse output back, compare) and section cardinality.

**Integration (real HiGHS binary):**
- `PlanWizard.generate/1` end-to-end: total duration, total rep count, pacing-style invariants, reservations within ±30s.
- **Legacy parity**: for `fatigue_factor = 0.0`, output matches the old solver within float tolerance. A golden fixture file `test/fixtures/planner_golden.exs` captures ~10 representative inputs and their expected outputs, regenerated once during the rewrite and locked thereafter.
- **Fatigue effect**: with `fatigue_factor > 0`, rest values are monotonically non-decreasing across non-zero-weight slots.

**Infeasibility:**
- Pace too fast → pre-LP error, HiGHS not invoked.
- Work doesn't fit → HiGHS reports infeasible → mapped to total-duration error.
- Reservation unplaceable within tolerance → HiGHS reports infeasible → mapped to `cannot_place_rest_out_of_tolerance_*`.

**CI:** HiGHS is built from source as part of CI image setup. README documents local build steps for developers.

## 8. Rollout Order

1. Add HiGHS build/install steps to README and CI image.
2. Implement `Lp` + `Lp.Problem` + `Mps` (pure; full property test coverage).
3. Implement `Highs` (real-binary integration tests).
4. Rewrite `Solver` to orchestrate the new pipeline.
5. Add `fatigue_factor` field (migration, schema, struct, defaults).
6. Update `PlansLive.Edit` form with fatigue control.
7. Delete legacy constraint modules and `Reservation`.
8. Append entry to `CHANGELOG.md`.

## 9. Non-goals

- Variable per-rep cadence (`sec_per_burpee[i]`) — out of scope; this design keeps pace constant per plan.
- Persistent solver process / IPC optimization — `System.cmd` per plan generation is acceptable given problem size.
- Re-generating existing stored plans — plans remain immutable once created.
- Exponential or piecewise fatigue ramps — start with linear; revisit if linear feels wrong in practice.
