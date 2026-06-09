# Block Pattern Editor Design

## Goal

Make workout plan editing feel like a training instrument instead of a low-level database form.

The user should be able to say:

> I want 70 Navy SEALs in 20 minutes, even pacing, grouped as a 4-rep set followed by a 3-rep set.

The system should then compute:

- how many times the block repeats,
- whether a remainder block is needed,
- pace,
- structural set recovery,
- and how explicit additional rests affect the execution timeline.

## Decisions

### 1. Use a solver-level block pattern preference

Add a user-facing block pattern preference, initially one reusable preferred block.

Example:

```text
Preferred block: 4 + 3
```

This means:

```text
Block 1
  Set 1: 4 reps
  Set 2: 3 reps
```

For a 70-rep target, the solver can generate:

```text
10 × Block 1 = 70 reps
```

The preference is not a manual frozen override. It is an input to the solver.

### 2. Use single preferred block plus automatic remainder

Only one preferred pattern is user-authored in the first version.

If the target does not divide evenly by the preferred block total, the solver creates an automatic remainder block.

Example:

```text
Goal: 75 reps
Preferred block: 4 + 3 = 7 reps
```

Output:

```text
10 × Block 1 = 70 reps
1 × Remainder Block = 5 reps
```

The user does not have to hand-author finisher blocks for awkward totals.

### 3. Additional rests remain explicit constraints

The solver should not invent additional rests by itself.

Additional rests are added later as user constraints:

```text
Rest 20s at 12:00
```

The solver recomputes the execution timeline around them.

Example:

```text
Goal: 70 Navy SEALs
Duration: 20:00
Preferred block: 4 + 3
Additional rest: 20s at 12:00
```

Output shape:

```text
6 × Block 1
Rest 20s
4 × Block 1
Finish 20:00
```

If a rest cannot be satisfied with the pattern and target duration, reject it with actionable feedback rather than silently producing an invalid plan.

### 4. Remove “Show structure”

Remove the current hidden low-level structure editor from the normal UX.

There should be no:

- “Show structure” button,
- separate nested block/set form as a secondary mode,
- old spreadsheet-like block editing panel.

The graph plus inspector becomes the editor.

## UX Design

Use the approved A+B direction from the mockups:

- A: pattern preference control,
- B: stable graph inspector.

Mockups:

```text
docs/superpowers/specs/2026-06-09-block-editor-ux-mockups.html
```

### Pattern preference control

Place the block pattern preference near the Style controls.

Example layout:

```text
Style
[ Even ] [ Unbroken ]

Block pattern
[ 4 ] [+ Set] [ 3 ]
7 reps/block · repeats 10×
```

Behavior:

- Editing a set rep count reruns the solver.
- Adding/removing a set reruns the solver.
- The repeat count is computed, not typed.
- Pace/rest are computed, not typed in the first version.

### Graph remains primary

The timeline graph remains the main plan surface.

It shows computed execution, for example:

```text
Start
10 × Block 1 · 70 reps
Finish · 20:00
```

With additional rest:

```text
Start
6 × Block 1 · 42 reps
Rest · +20s recovery
4 × Block 1 · 28 reps
Finish · 20:00
```

### Stable inspector

Clicking a block opens a stable inspector.

The inspector edits the preferred pattern or the selected block pattern, not every repeated generated copy.

The inspector must not collapse when inputs are focused or changed.

Initial inspector fields:

```text
Block 1 pattern
Set 1: [4] reps
Set 2: [3] reps
[+ Set]
```

The inspector can show computed values read-only:

```text
Repeats: 10×
Total: 70 reps
Pace: 16.9s/rep
Finish: 20:00
```

## Domain Model Direction

Keep the existing first-principles split:

- `Block` = reusable structure/pattern,
- `Set` = movement prescription inside a block,
- `PlanStep` = ordered executable step,
- `Rest` = first-class execution step.

Extend solver input with a block pattern preference.

Conceptually:

```elixir
%Input{
  pacing_style: :even,
  burpee_count_target: 70,
  target_duration_min: 20,
  block_pattern: [4, 3],
  additional_rests: []
}
```

Solver output:

```elixir
%WorkoutPlan{
  blocks: [
    %Block{position: 1, sets: [%Set{burpee_count: 4}, %Set{burpee_count: 3}]}
  ],
  steps: [
    %PlanStep{kind: :block_run, block_position: 1, repeat_count: 10}
  ]
}
```

With rest:

```elixir
steps: [
  %PlanStep{kind: :block_run, block_position: 1, repeat_count: 6},
  %PlanStep{kind: :rest, rest_sec: 20},
  %PlanStep{kind: :block_run, block_position: 1, repeat_count: 4}
]
```

## Solver Behavior

### Even pacing

For even pacing, the solver should distribute total available work time across all reps.

```text
available_work_time = target_duration - explicit_additional_rests
pace = available_work_time / total_reps
```

The pattern controls grouping, not total work.

Structural rest inside the preferred block can be computed later if needed, but the first version should prefer simple even cadence unless the design explicitly needs internal rest.

### Unbroken pacing

For unbroken pacing, the preferred pattern can replace the current single `reps_per_set` concept.

Example:

```text
Preferred block: 5
```

is equivalent to today’s `reps_per_set = 5`.

A multi-set pattern like `4 + 3` means repeated blocks rather than identical one-set repeats.

### Remainders

If `total_reps` is not divisible by `block_total`, create a remainder block that consumes the remaining reps.

Remainder block generation should preserve the user’s pattern order as much as possible.

Example:

```text
Pattern: 4 + 3
Remainder: 5
```

Potential remainder:

```text
Set 1: 4
Set 2: 1
```

## Error Handling

Show actionable feedback when constraints cannot be satisfied.

Examples:

```text
This block pattern cannot produce 70 reps without a remainder.
```

```text
Rest at minute 12 cannot be placed on a block boundary for this pattern.
Try moving it to 11:48 or 12:09, or choose a smaller block pattern.
```

```text
70 reps plus 20s rest cannot fit in 20:00 at the selected pace limit.
Increase duration or reduce reps.
```

Do not silently accept impossible rests.
Do not fold additional rests into set recovery.

## Testing Plan

Add tests for:

1. Even style with preferred pattern `4 + 3`, 70 reps, 20 minutes:
   - one block definition with two sets,
   - one block-run step repeated 10 times,
   - summary reports 70 reps and 20:00.

2. Same plan with additional rest 20s at minute 12:
   - block-run/rest/block-run steps,
   - rest is first-class,
   - finish remains 20:00.

3. Remainder behavior:
   - 75 reps with pattern `4 + 3` creates 10 full block repeats plus a 5-rep remainder block.

4. UI pattern editor:
   - changing set reps reruns solver,
   - graph updates,
   - inspector remains open while editing.

5. Removal of old structure editor:
   - no `Show structure` button,
   - no legacy nested structure panel in normal UX.

## Non-goals for First Version

- Multiple authored block patterns.
- Solver-invented automatic additional rests.
- Full manual low-level block surgery.
- Per-set pace/rest preferences in the pattern editor.
- Drag-and-drop graph editing.

These can be added later if the first version feels good.
