# Burpee Trainer — Plan Solver v3

> **Status:** implementation specification  
> **Scope:** replace the current session-level candidate search while keeping `Execution`, `Apply`, persisted-plan validation, and the editor integration where possible.  
> **Source of truth:** this document wins over legacy helper names, heuristic weights, and reset-placement rules.

## 1. Goal

Build a deterministic solver that turns fixed workout intent into an exact, human-shaped prescription.

The user chooses:

- burpee type
- total duration
- total reps
- workout style: `:even` or `:unbroken`
- for `:unbroken`, the maximum allowed reps in any unbroken set
- optionally, an exact advanced block structure
- optionally, explicit additional rests

The solver must **not** choose the workout style. It must solve within the selected style.

For an unbroken workout, the solver should be able to produce structures such as:

```text
140 reps · six-count · 20:00 · unbroken · max 8 reps/set

Block 1   5 × [8]
Block 2   5 × [7]
Block 3   5 × [7, 6]

Normal recovery   15s
Reset recovery    around minute 12
Late reset         around minute 18
```

The result must balance:

- no pace faster than the burpee type permits
- a pace that is neither unnecessarily fast nor unnecessarily slow
- useful recovery after unbroken sets
- one or two longer reset recoveries at useful elapsed-time windows
- a simple, readable block structure
- exact target reps and exact target duration

This is a small finite search problem. Use a custom grammar-constrained search with dynamic programming and bounded enumeration. Do not model every rest gap as an unconstrained MILP variable.

---

## 2. Non-goals

Version 3 does not:

- choose between `:even` and `:unbroken`
- invent or change the user's exact advanced block structure
- use a learned physiology model
- optimize weekly scheduling or catch-up allocation
- expose optimizer atoms in the UI
- silently violate the minimum rep time
- silently regenerate old saved plans when merely opening them

A learned fatigue model can later replace some ranking policies, but the first implementation must remain explicit, deterministic, and testable.

---

## 3. Domain terminology

Use names that respect the direction of seconds-per-rep values.

### Pace

`sec_per_rep` is the movement time for one burpee.

- lower value = faster
- higher value = slower
- `hard_fastest_sec_per_rep` is a lower numeric bound
- `hard_slowest_sec_per_rep` is an upper numeric bound

Do not use ambiguous names such as `pace_min` when it is unclear whether “minimum” means fastest or slowest.

### Unbroken set

A sequence of consecutive reps with no intentional recovery between them.

```text
rep rep rep rep → recovery
```

For set `i` with `s_i` reps:

```text
work_i = s_i × sec_per_rep
```

Recovery may exist only after the set. The final set has no trailing recovery.

### Even pacing

Reps are separated by a regular cadence gap:

```text
rep → gap → rep → gap → rep
```

The solver does not convert even pacing into unbroken sets.

### Normal recovery

The ordinary recovery used after most unbroken sets.

### Reset recovery

A longer automatic recovery that replaces the normal recovery at one set boundary. It is not added on top of normal recovery.

### Explicit additional rest

A user-requested rest. It is a mandatory event and is included in the same canonical timeline search. It may add to the recovery at its selected boundary, but it remains a separately sourced event.

### Block

A readable repeated motif:

```elixir
%BlockSpec{repeat: 5, motif: [8]}
%BlockSpec{repeat: 5, motif: [7, 6]}
```

Expansion:

```text
5 × [8]    -> 8, 8, 8, 8, 8
5 × [7,6]  -> 7, 6, 7, 6, 7, 6, 7, 6, 7, 6
```

Blocks are a user-facing workout concept, not merely persistence containers.

---

## 4. Public input contract

Replace or normalize the current solver input into this domain contract:

```elixir
defmodule BurpeeTrainer.PlanSolver.Input do
  @enforce_keys [
    :burpee_type,
    :target_duration_sec,
    :burpee_count_target,
    :pacing_style
  ]

  defstruct [
    :name,
    :burpee_type,
    :target_duration_sec,
    :burpee_count_target,
    :pacing_style,
    :max_unbroken_reps,
    :block_structure,
    :explicit_rests,
    :sec_per_rep_override
  ]
end
```

### Required semantics

```text
burpee_type          determines the base pace policy
target_duration_sec  positive integer seconds
burpee_count_target  positive integer
pacing_style         :even | :unbroken
```

For `:unbroken`:

```text
max_unbroken_reps    required positive integer
```

For `:even`:

```text
max_unbroken_reps    ignored and should normally be nil
```

### Optional advanced block structure

Canonical form:

```elixir
[
  %BlockSpec{repeat: 5, motif: [8]},
  %BlockSpec{repeat: 5, motif: [7]},
  %BlockSpec{repeat: 5, motif: [7, 6]}
]
```

When supplied, it is exact:

- expand it to the set sequence
- require the expanded reps to equal `burpee_count_target`
- require every set to be within `1..max_unbroken_reps`
- do not change, reorder, merge, split, or “improve” it
- solve only pace, normal recovery, reset recovery, and rest placement

Support the current raw `block_pattern` or set-list representation through an adapter at the boundary. Do not keep both representations inside the new solver core.

### Optional pace override

`sec_per_rep_override`, when retained for compatibility, is a hard lock:

- validate it against hard bounds
- derive the available rest budget from it
- never silently alter it
- return infeasible if no legal human-shaped rest allocation exists

---

## 5. Pace policy

The problem is underdetermined with only a fastest legal pace. “Not too fast and not too slow” requires an explicit preferred band.

Add:

```elixir
defmodule BurpeeTrainer.PlanSolver.PacePolicy do
  defstruct [
    :hard_fastest_sec_per_rep,
    :preferred_fast_sec_per_rep,
    :preferred_slow_sec_per_rep,
    :hard_slowest_sec_per_rep
  ]
end
```

Contract:

```text
hard_fastest <= preferred_fast <= preferred_slow <= hard_slowest
```

Initial static defaults may be configured per burpee type. Seed values:

```elixir
%{
  six_count: %PacePolicy{
    hard_fastest_sec_per_rep: 3.7,
    preferred_fast_sec_per_rep: 4.8,
    preferred_slow_sec_per_rep: 5.8,
    hard_slowest_sec_per_rep: 7.0
  },
  navy_seal: %PacePolicy{
    hard_fastest_sec_per_rep: 8.0,
    preferred_fast_sec_per_rep: 9.0,
    preferred_slow_sec_per_rep: 11.0,
    hard_slowest_sec_per_rep: 13.0
  }
}
```

Put these values behind one policy module so they can later be personalized from session history.

Do not carry forward the current `0.92` pace-floor relaxation. Hard bounds are hard.

### Pace classification

```elixir
:too_fast     # below preferred_fast but still within the hard bound
:comfortable  # inside preferred band
:too_slow     # above preferred_slow but still within the hard bound
```

A result outside the preferred band may be returned only when no preferred-band candidate exists. It must be marked in metadata.

---

## 6. Canonical output model

Introduce a solver-domain prescription before converting to persisted blocks:

```elixir
defmodule BurpeeTrainer.PlanSolver.Prescription do
  defstruct [
    :pacing_style,
    :burpee_type,
    :target_duration_sec,
    :burpee_count,
    :sec_per_rep,
    :cadence_sec,
    :blocks,
    :set_pattern,
    :recoveries,
    :execution,
    :score,
    :metadata
  ]
end
```

For unbroken prescriptions:

```elixir
%Recovery{
  after_set: 13,
  total_sec: 90,
  kind: :reset,
  source: {:auto_reset, :mid}
}
```

Normal recoveries may be represented explicitly per gap in the canonical prescription even when they share one default value.

The solver result should contain the readable `blocks` and the expanded `set_pattern`. Do not force the UI to infer the intended block grammar from persisted atoms.

`Execution` remains the source of truth for exact event ordering and timing.

---

## 7. Global invariants

A returned solution must satisfy all of these:

1. Total reps equal the target exactly.
2. Canonical execution duration equals the target exactly within solver precision.
3. Persisted plan summary matches canonical execution.
4. Selected pacing style is unchanged.
5. No pace is faster than `hard_fastest_sec_per_rep`.
6. No pace is slower than `hard_slowest_sec_per_rep`.
7. For unbroken workouts, every set is `<= max_unbroken_reps`.
8. There is no automatic or implicit trailing rest after the final rep/set.
9. Reset recoveries occur only at legal set boundaries.
10. A reset recovery replaces normal recovery at that boundary.
11. Explicit rests are included during candidate search, not patched in afterward.
12. An exact advanced block structure is preserved byte-for-byte at the domain level.
13. The same normalized input always returns the same prescription.
14. Candidate ordering must not depend on map iteration order, process scheduling, or floating-point accidents.

---

## 8. Solver architecture

```text
PlanSolver.solve/1
  |
  +-- Input.normalize_and_validate/1
  +-- PacePolicy.for/1
  |
  +-- :even
  |     `-- EvenSolver.solve/2
  |
  `-- :unbroken
        +-- StructureSearch.generate/2
        +-- RecoverySearch.solve/3
        +-- BoundaryPlacement.place/3
        `-- CandidateScore.best/1

Prescription
  -> Execution.build/1
  -> Validator.validate/2
  -> Apply.from_execution/3
  -> Validator.validate_persisted_plan/2
  -> Solution
```

Recommended modules:

```text
BurpeeTrainer.PlanSolver.Input
BurpeeTrainer.PlanSolver.PacePolicy
BurpeeTrainer.PlanSolver.BlockSpec
BurpeeTrainer.PlanSolver.Prescription
BurpeeTrainer.PlanSolver.StructureSearch
BurpeeTrainer.PlanSolver.RecoverySearch
BurpeeTrainer.PlanSolver.BoundaryPlacement
BurpeeTrainer.PlanSolver.CandidateScore
BurpeeTrainer.PlanSolver.EvenSolver
BurpeeTrainer.PlanSolver.UnbrokenSolver
BurpeeTrainer.PlanSolver.Validator
```

Keep:

```text
BurpeeTrainer.PlanSolver.Execution
BurpeeTrainer.PlanSolver.Apply
BurpeeTrainer.PlanSolver.Solution
```

Rename and remove legacy helpers containing `milp` when they no longer call MILP.

---

## 9. Even solver

Even pacing is a separate deterministic branch. It is not a candidate in the unbroken search.

Version 3 policy:

- use one continuous rep stream
- use a regular cadence between rep starts
- do not generate automatic long reset recoveries, because that contradicts even pacing
- preserve explicit user rests, if any
- use a comfortable movement pace whenever the duration permits it

For `N > 1`, with movement time `p`, explicit-rest total `E`, and cadence `c`:

```text
T = p + (N - 1) × c + E
c = (T - E - p) / (N - 1)
```

Require:

```text
c >= p
hard_fastest <= p <= hard_slowest
```

Choose `p` as the slowest comfortable value that still permits `c >= p`:

```text
available_average = (T - E) / N
p = min(preferred_band_midpoint, available_average)
```

Reject if `available_average < hard_fastest_sec_per_rep`.

For `N == 1`, build one rep event and place explicit rest only where the product semantics permit it; otherwise require the target duration to equal the selected rep duration or return an actionable infeasibility error.

Use actual execution boundaries when placing explicit rests.

---

## 10. Unbroken solver overview

For an expanded set sequence:

```text
s_1, s_2, ..., s_k
```

and recovery after every non-final set:

```text
r_1, r_2, ..., r_(k-1)
```

exact duration is:

```text
T = N × p + sum(r_i) + explicit_rest_total
```

Therefore:

```text
p = (T - sum(r_i) - explicit_rest_total) / N
```

The solver should not independently optimize pace and rest. It must:

```text
generate a readable structure
-> generate a readable recovery template
-> place special rests at real elapsed-time boundaries
-> derive exact pace
-> reject hard-infeasible candidates
-> rank feasible candidates lexicographically
```

---

## 11. Structure search

### 11.1 Manual path

When `block_structure` is supplied:

```text
structures = [validated_user_structure]
```

Skip generated structure search completely.

### 11.2 Generated grammar

Generated blocks use this grammar:

```text
Plan  := Block{1..4}
Block := repeat(q, Motif)
Motif := [a] | [a, b]
```

Constraints:

```text
1 <= a,b <= max_unbroken_reps
abs(a - b) <= 1
1 <= q <= 12
expanded total reps == target reps
adjacent identical blocks are merged
block average load is non-increasing
```

For generated plans, prefer but do not hard-require:

- motif length 1 or 2 only
- 2–4 blocks
- 4–6 motif repetitions per block
- first block reaches the user's maximum set size
- one to three distinct set sizes
- later block averages are equal to or below earlier block averages
- for sessions `>= 18 minutes`, a total taper of roughly 1–2 reps from first-block average to final-block average
- no tiny remainder set

A repeated two-set motif such as `[7, 6]` is preferred over a final isolated remainder set.

### 11.3 Search algorithm

Use memoized depth-first search or forward dynamic programming over block productions.

Suggested state:

```elixir
{
  reps_allocated,
  blocks_used,
  previous_block_max,
  previous_block_average_bucket
}
```

Each transition appends one legal `BlockSpec`.

Prune when:

- reps exceed target
- block count exceeds 4
- remaining reps cannot be represented within remaining blocks
- block average would increase
- a duplicate adjacent block should have been merged

Keep only the best bounded set of partial structures per state, using structure-only ranking. A cap of 32–64 complete structures is sufficient before recovery search.

### 11.4 Completeness fallback

The block grammar is a readability grammar, not a reason to declare an otherwise feasible workout impossible.

If no grammar candidate exactly represents the target:

1. Enumerate feasible set counts.
2. Produce balanced integer partitions where every set is `<= max_unbroken_reps`.
3. Arrange larger sets earlier and distribute remainder smoothly.
4. Compress the set sequence into the fewest readable blocks possible.

Mark fallback metadata:

```elixir
structure_strategy: :balanced_fallback
```

Never emit a final one- or two-rep scrap set when a more even partition exists.

---

## 12. Recovery search

### 12.1 Human-readable recovery values

Put candidate values in configuration rather than inside the algorithm:

```elixir
normal_recovery_candidates_sec: [8, 10, 12, 15, 18, 20, 25]
reset_recovery_candidates_sec: [45, 60, 75, 90, 105, 120, 150, 180]
```

All values are total recovery at a boundary.

Use one global normal recovery in version 3. Per-block normal recovery can be added later only if golden cases demonstrate a real need.

### 12.2 Automatic reset windows

Automatic reset count is bounded by duration:

```text
T < 12 min       -> 0 resets
12 <= T < 18 min -> 0 or 1 reset
T >= 18 min      -> 0, 1, or 2 resets
```

Preferred windows:

```text
mid reset:
  center = 0.60 × T
  legal window = [0.55 × T, 0.67 × T]

late reset:
  center = 0.90 × T
  legal window = [0.85 × T, 0.96 × T]
```

For a 20-minute workout:

```text
mid window  = 11:00–13:24, center 12:00
late window = 17:00–19:12, center 18:00
```

A late reset must leave at least one full set after it. There is no reset after the final set.

Do not derive reset positions from `round(gap_count * 0.75)` or “last gap.” Evaluate actual elapsed timestamps.

### 12.3 Candidate enumeration

For each structure:

```text
for each normal recovery value
for each allowed reset count
for each reset duration combination
for each legal boundary placement
  derive total recovery
  derive exact sec_per_rep
  reject hard-infeasible pace
  build canonical execution
  score candidate
```

Because there are usually fewer than 50 sets and at most two automatic resets, exhaustive boundary enumeration is cheap.

### 12.4 Reset semantics

At a reset boundary:

```text
recovery_after_set = reset_recovery_sec
```

not:

```text
normal_recovery_sec + reset_recovery_sec
```

Record both the kind and source so the UI can label it correctly.

### 12.5 Explicit user rests

Explicit rests participate in the same boundary-placement search.

Each explicit rest should contain:

```elixir
%ExplicitRest{
  target_elapsed_sec: 720,
  duration_sec: 60,
  tolerance_sec: 60
}
```

Rules:

- place it only at a valid rep/set boundary
- preserve its duration exactly
- require actual start time to be inside its tolerance window
- include its duration before deriving pace
- do not place an automatic reset at the same boundary
- do not use an approximate rest pattern to place it
- return an actionable error if no canonical candidate can place it

This replaces the current post-selection additional-rest patching path.

---

## 13. Candidate scoring

Do not use a single weighted scalar such as:

```text
pace × 10_000 + normal_rest × 100 - reset_count × 500
```

Use lexicographic comparison. Hard constraints are rejected before scoring.

Recommended score key:

```elixir
{
  pace_band_violation_ms,
  explicit_rest_target_error_ms,
  reset_count_miss,
  reset_window_error_ms,
  structure_shape_penalty,
  structure_complexity_penalty,
  pace_midpoint_error_ms,
  normal_recovery_preference_error,
  canonical_tiebreaker
}
```

Lower is better.

### 13.1 Pace-band violation

```elixir
def band_distance(p, preferred_fast, preferred_slow) do
  cond do
    p < preferred_fast -> preferred_fast - p
    p > preferred_slow -> p - preferred_slow
    true -> 0.0
  end
end
```

This is the first soft objective. A plan in the preferred band beats any plan outside it.

### 13.2 Explicit-rest error

Explicit rests are already constrained by a hard tolerance. Within that tolerance, prefer the closest legal boundary.

### 13.3 Reset-count miss

Preferred automatic reset count:

```text
T < 12 min       -> 0
12 <= T < 18 min -> 1
T >= 18 min      -> 2
```

This is a preference, not a hard requirement. A comfortable one-reset workout may beat an uncomfortable two-reset workout because pace-band violation is ranked first.

### 13.4 Reset-window error

Sum absolute elapsed-time error from each reset's target center.

### 13.5 Structure-shape penalty

Use a tuple or integer composed from explicit policies:

- penalty when the first block does not use `max_unbroken_reps`
- penalty when final-block average exceeds first-block average
- penalty when a long workout does not taper by roughly 1–2 reps
- penalty for a tiny final set
- penalty for more than three distinct set sizes
- penalty for uneven block repetition counts

Do not invent a pseudo-scientific fatigue score in version 3. The hard max set size, comfortable pace band, taper policy, and reset windows are the transparent fatigue controls.

### 13.6 Structure complexity

Prefer, in order:

- fewer block types
- fewer distinct set sizes
- repeated motifs
- fewer one-off sets
- fewer blocks when shape quality is otherwise equal

### 13.7 Pace midpoint

Within the preferred band, prefer the midpoint only after useful recovery placement and readable structure have been considered.

### 13.8 Canonical tie-breaker

Use a stable serialized key such as:

```text
block encoding
normal recovery
reset count
reset durations
reset indexes
exact pace numerator/denominator
```

Never rely on enumeration accident.

---

## 14. Numeric representation

Do not let display rounding change the solved duration.

Preferred implementation:

- target and rests in integer milliseconds
- derive pace as an exact rational numerator over total reps, or use `Decimal`
- build timestamps from exact internal values
- round only in presentation

At minimum:

- retain full float precision internally
- use a strict small epsilon for canonical validation
- never round `sec_per_rep` before building execution
- persist enough precision to reconstruct the same duration

Human-visible pace may be shown to one decimal place even when canonical pace is more precise.

---

## 15. Reference examples

This section gives examples, not a single generated shape that the solver must always force.

Input:

```elixir
%Input{
  burpee_type: :six_count,
  target_duration_sec: 1_200,
  burpee_count_target: 140,
  pacing_style: :unbroken,
  max_unbroken_reps: 8
}
```

A generated solution may choose a simple uniform structure:

```text
Block 1   20 × [7]

Expanded sets:
7,7,7,7,7,
7,7,7,7,7,
7,7,7,7,7,
7,7,7,7,7
```

This is acceptable because it is exact, readable, stable, and every set is below the max of 8.

Another acceptable structure is a tapered plan:

```text
Block 1   5 × [8]
Block 2   5 × [7]
Block 3   5 × [7, 6]

Expanded sets:
8,8,8,8,8,
7,7,7,7,7,
7,6,7,6,7,6,7,6,7,6
```

This tapered structure is especially desirable when the user supplies it as an exact advanced block structure. In manual-structure mode, the solver must preserve it exactly and solve only pace, normal recovery, reset recovery, and rest placement.

With either 20-set structure, a valid recovery plan may be:

```text
Normal recovery: 15s
Reset after set 13: 90s total
Reset after set 19: 90s total
```

There are 19 recovery gaps:

```text
17 normal gaps × 15s = 255s
2 reset gaps × 90s   = 180s
Total recovery       = 435s
```

Exact pace:

```text
p = (1,200 - 435) / 140
p = 5.464285714... sec/rep
```

Timeline properties should be validated by elapsed time, not by fixed set indexes:

```text
mid reset starts inside 11:00–13:24 for a 20-minute workout
late reset starts inside 17:00–19:12 for a 20-minute workout
session ends = 20:00.0 exactly
```

Generated-structure tests must assert product-level properties rather than a single exact block shape. Exact block-shape tests belong to manual-structure preservation.

---

## 16. Infeasibility and warnings

Return typed errors rather than generic strings:

```elixir
%Infeasible{
  reason: :work_alone_exceeds_duration,
  details: %{...},
  suggestions: [...]
}
```

Reasons should include:

```text
:invalid_input
:advanced_structure_rep_mismatch
:set_exceeds_max_unbroken
:work_alone_exceeds_duration
:no_pace_within_hard_bounds
:cannot_place_explicit_rest
:no_human_shaped_recovery_allocation
```

Suggested remedies may include:

- reduce total reps
- increase duration
- increase maximum unbroken set size
- remove or shorten an explicit rest
- provide a different manual block structure

If a solution is inside hard bounds but outside the preferred band, return it with:

```elixir
pace_status: :too_fast | :too_slow
warning: "Target requires a faster/slower pace than the preferred band."
```

Never silently relax a hard bound.

---

## 17. Metadata and observability

Replace opaque scalar score metadata with explainable fields:

```elixir
%{
  solver_version: 3,
  strategy: :generated_grammar | :manual_structure | :balanced_fallback | :even,
  generated_candidate_count: 412,
  feasible_candidate_count: 37,
  pace_status: :comfortable,
  pace_policy: %{...},
  score_key: {...},
  normal_recovery_sec: 15,
  auto_resets: [
    %{kind: :mid, after_set: 13, starts_at_sec: 699.107, duration_sec: 90},
    %{kind: :late, after_set: 19, starts_at_sec: 1077.214, duration_sec: 90}
  ],
  structure_key: "5x[8]|5x[7]|5x[7,6]"
}
```

Add debug-only access to the top few feasible candidates, but return one canonical prescription to normal application code.

---

## 18. Persistence and editor behavior

### Persist solver version

Every generated plan must persist `solver_version` and enough prescription metadata to explain the selected structure.

### Do not mutate saved plans on open

Loading an existing plan must show its persisted prescription. Do not rerun the newest solver merely because generated metadata exists.

Regenerate only when:

- the user edits solver inputs
- the user presses an explicit regenerate action
- a deliberate migration is run

This prevents Solver v3 from silently changing old plans.

### Presentation

Prefer rendering from `Prescription.blocks` or persisted prescription metadata. `PlanPresentation` may retain a fallback that reconstructs an outline from old persisted atoms.

The default UI must continue to show a workout outline, not every execution event.

---

## 19. Migration from the current implementation

1. Add `PacePolicy`, `BlockSpec`, `Prescription`, `StructureSearch`, `RecoverySearch`, `BoundaryPlacement`, and `CandidateScore`.
2. Add Solver v3 behind an internal feature flag.
3. Build reference, manual-structure, and property tests before switching the editor.
4. Route unbroken inputs to `UnbrokenSolver`.
5. Move explicit-rest placement into the candidate search.
6. Keep `Execution`, `Apply`, and final persisted-plan validation.
7. Change presentation to prefer canonical prescription blocks.
8. Persist `solver_version: 3`.
9. Stop automatic regeneration when opening saved generated plans.
10. Delete or retire:
    - fixed reset positions based on gap percentages
    - fixed `90s`-only reset search
    - weighted scalar objective
    - pace-floor relaxation
    - legacy `solve_milp_*` names
    - post-selection approximate additional-rest placement
11. Keep generic HiGHS infrastructure for weekly scheduling or other genuinely combinatorial allocation problems; do not use it for unconstrained per-gap rests.

---

## 20. Tests

### 20.1 Unit tests

Test independently:

- block expansion
- advanced structure validation
- grammar transitions
- balanced fallback partitioning
- pace-band distance
- exact pace derivation
- reset-window calculation
- boundary placement from actual elapsed time
- lexicographic score comparison
- deterministic canonical tie-breaking

### 20.2 Reference prescription tests

At minimum:

1. `140 reps / six-count / 20 min / unbroken / max 8` generated mode returns a readable exact plan, not one hardcoded block shape. Acceptable generated structures include `20 × [7]` and `5 × [8] | 5 × [7] | 5 × [7,6]` if all global invariants hold.
2. A manual `5 × [8] | 5 × [7] | 5 × [7,6]` structure is preserved exactly.
3. A target requiring faster than the hard fastest pace returns infeasible.
4. A target outside the preferred band but inside hard bounds returns a warning, not an error.
5. A 20-minute workout may use two useful resets when pace remains comfortable, but reset placement is judged by elapsed-time windows rather than exact set indexes.
6. A 14-minute workout never receives a late reset.
7. A short workout under 12 minutes receives no automatic reset.
8. An explicit rest is placed using canonical execution boundaries.
9. No solution has trailing rest.
10. Even pacing never becomes unbroken.

### 20.3 Property tests

For generated feasible inputs:

```text
sum(set_pattern) == target reps
all set sizes <= max unbroken
execution duration == target duration
persisted summary == execution summary
no final recovery
hard_fastest <= sec_per_rep <= hard_slowest
block averages are non-increasing for generated grammar plans
same input produces identical output
```

Use a broad table of durations, rep targets, burpee types, and maximum set sizes. Tests should assert product-level shape, not only arithmetic validity.

### 20.4 Regression tests

Lock bugs for:

- explicit rest placed from an approximate rather than selected rest pattern
- reset after final set
- adjacent auto resets
- pace made faster by a hidden relaxation
- tiny remainder set when a balanced partition exists
- saved plan changing merely because it was opened

---

## 21. Performance target

Typical solve target:

```text
< 20 ms in production for ordinary 20–40 minute sessions
```

Hard safety cap:

```text
< 100 ms and bounded candidate counts
```

Use:

- DP/memoization for structure generation
- top-K pruning before recovery search
- at most two automatic resets
- stable bounded candidate grids

Do not add concurrency until profiling demonstrates a need. Sequential deterministic enumeration is preferable at this scale.

---

## 22. Reference pseudocode

```elixir
def solve(%Input{} = raw_input) do
  with {:ok, input} <- Input.normalize_and_validate(raw_input),
       policy <- PacePolicy.for(input.burpee_type),
       {:ok, prescription} <- solve_style(input, policy),
       execution <- Execution.build(prescription),
       :ok <- Validator.validate_execution(input, prescription, execution),
       {:ok, plan} <- Apply.from_execution(input, execution, prescription),
       :ok <- Validator.validate_persisted_plan(input, execution, plan) do
    {:ok, Solution.from(prescription, execution, plan)}
  end
end


defp solve_style(%{pacing_style: :even} = input, policy) do
  EvenSolver.solve(input, policy)
end


defp solve_style(%{pacing_style: :unbroken} = input, policy) do
  structures =
    case input.block_structure do
      nil -> StructureSearch.generate(input, policy)
      blocks -> [StructureSearch.validate_manual!(blocks, input)]
    end

  candidates =
    structures
    |> Enum.flat_map(fn structure ->
      RecoverySearch.candidates(input, policy, structure)
    end)
    |> Enum.filter(&Validator.hard_feasible?/1)

  case candidates do
    [] -> {:error, Infeasible.from_search(input, policy, structures)}
    _ -> {:ok, Enum.min_by(candidates, &CandidateScore.key/1)}
  end
end
```

Recovery search:

```elixir
def candidates(input, policy, structure) do
  for normal_sec <- recovery_policy().normal_candidates,
      reset_template <- reset_templates(input.target_duration_sec),
      placement <- BoundaryPlacement.enumerate(structure, reset_template, input.explicit_rests),
      candidate = build_candidate(input, policy, structure, normal_sec, placement),
      hard_feasible?(candidate) do
    candidate
  end
end
```

Candidate construction:

```elixir
def build_candidate(input, policy, structure, normal_sec, placement) do
  total_auto_recovery = recovery_total(structure, normal_sec, placement.auto_resets)
  explicit_total = Enum.sum_by(input.explicit_rests, & &1.duration_sec)

  sec_per_rep =
    (input.target_duration_sec - total_auto_recovery - explicit_total) /
      input.burpee_count_target

  execution =
    Execution.preview(
      structure,
      sec_per_rep,
      normal_sec,
      placement
    )

  %Candidate{
    structure: structure,
    sec_per_rep: sec_per_rep,
    normal_recovery_sec: normal_sec,
    placement: placement,
    execution: execution,
    score: CandidateScore.key(...)
  }
end
```

---

## 23. Definition of done

Solver v3 is complete when:

- the user-selected style is never changed
- manual block structure is exact
- generated unbroken plans use readable repeated blocks
- pace is derived from exact duration and selected recovery
- comfortable pace is preferred without arbitrary scalar weights
- reset rests are placed by real elapsed time
- explicit rests are solved jointly with the base workout
- the 140-rep generated reference case passes property-level acceptance without overfitting to one shape
- the manual 140-rep tapered structure is preserved exactly
- all returned executions and persisted plans have exact reps and duration
- saved plans do not mutate merely by being opened
- the UI can display the generated blocks without reverse-engineering optimizer residue
