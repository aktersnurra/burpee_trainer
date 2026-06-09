# Smart Prescription + Graph Editor Design

## Goal

Replace the current literal plan editor with a smart training prescription builder.

The user should be able to enter:

```text
20:00
160 reps
Style: even or unbroken
```

and receive a human-friendly workout, not a mathematically valid but unusable plan like one 160-rep set.

The editor should make the workout understandable and natural to modify through the graph itself, with minimal clicks and no surprise layout shifts.

## Problems to Fix

1. **Even plans are too literal.** One set with all reps is technically valid but not a reasonable prescription.
2. **Unbroken plans are arithmetic-first.** Rest is whatever remains, instead of being balanced as training recovery.
3. **The UI separates preview from editing.** The graph explains the plan, but editing still feels like forms/cards bolted onto it.
4. **Feedback is not trust-building.** Errors and generated choices do not explain why a prescription is or is not feasible.

## Core Model

A set is a work interval, not merely a rep count.

Usually one set maps to about one minute of work:

```text
8 reps  -> ~1:00 work
10 reps -> ~1:00-1:10 work
```

But larger unbroken sets can naturally become longer intervals:

```text
15 reps -> ~1:30 work
```

The solver should choose pace and recovery together:

- keep pace appropriate for the user level,
- allow small pace increases to preserve useful recovery,
- reject prescriptions that require burnout-level pace,
- avoid useless rests such as 2s unless explicitly forced,
- avoid huge repeated rests unless the structure calls for them.

Pace and recovery remain **auto** in normal mode. The user edits intent and structure; the system handles arithmetic.

## Smart Prescription Generator

The generator should search candidate prescriptions and rank them by training quality.

### Inputs

Required:

- target duration,
- target reps,
- burpee type,
- pacing style,
- user level.

Optional:

- preferred reps per set,
- preferred block pattern,
- explicit additional rests.

### Candidate structure

For both `:even` and `:unbroken`, generate human-sized structures:

```text
20 x Block 1
Block 1: 8 reps
```

or:

```text
10 x Block 1
Block 1: 15 reps
Remainder: 10 reps
```

Even pacing should still use blocks and sets. “Even” means even cadence / finish timing, not “one giant set.”

### Work interval targets

Candidate sets should prefer work intervals near these bands:

- normal set: ~45-75s work,
- longer unbroken set: ~75-105s work,
- avoid tiny sets that create noisy plans,
- avoid giant sets unless the user explicitly asks.

### Recovery targets

Recovery is computed, not typed.

Prefer:

- enough recovery after each set to be meaningful,
- consistent recovery for repeated blocks,
- lower recovery only when pace remains safe,
- explicit rest steps when they improve structure.

### Optional midpoint rest suggestion

The solver may suggest, but should not silently force, a reset rest in the “no man’s land” zone, roughly 10-16 minutes into a 20-minute workout.

Example:

```text
Suggestion: Add 30s reset at 12:00
Effect: set recovery changes from 17s to 15s
```

Suggestions must only appear when they fit without making pace unsafe or set recovery useless.

Explicit user-added rests remain first-class `PlanStep :rest` items and must never be folded into set recovery.

## Ranking Heuristics

Rank candidates by:

1. feasible within level pace bounds,
2. human work intervals,
3. meaningful set recovery,
4. simple repeated blocks,
5. low remainder awkwardness,
6. minimal surprise rests,
7. clean explanation.

The top candidate becomes the default. Alternatives can be offered later, but the first version only needs a single good recommendation plus optional rest suggestion.

## Graph-First Editor

The graph is the primary editing surface.

The user should not look for a hidden form field. They should click the part of the workout they want to change.

### Layout

```text
Goal bar
20:00 · 160 reps · Unbroken

Prescription graph
Start
20 x Block 1        8 reps · ~1:00 work · 17s recovery
Optional reset      30s at 12:00
Finish              20:00

Inspector
Selected: Block 1
[ reps/set: 8 ]
Work: auto · ~1:00
Recovery: auto · 17s
Why: preserves recovery while staying within level pace.
```

### Goal bar

Compact global intent controls:

- duration,
- target reps,
- style,
- burpee type if needed.

Changing these reruns the prescription generator.

### Graph nodes

Graph node types:

- block run,
- rest,
- finish summary.

Block nodes show:

- repeat count,
- block name,
- total reps,
- set pattern,
- work/recovery summary.

Rest nodes show:

- rest duration,
- placement,
- effect on plan.

Edges can expose a single quick action:

```text
+ Rest here
```

### Stable inspector

Clicking a graph node updates one stable inspector area.

The inspector must not:

- create a second card beside the graph,
- move the graph around unexpectedly,
- collapse on input focus,
- turn one selected card into two cards.

Inspector modes:

#### Block inspector

Normal controls:

- reps per set,
- block pattern if the block has multiple sets,
- reset to recommended.

Read-only auto explanations:

- work interval,
- pace,
- recovery,
- repeat count,
- why this structure was chosen.

#### Rest inspector

Controls:

- rest duration,
- placement preset / minute,
- remove rest.

Read-only explanation:

- how this changes pace/recovery,
- whether it remains feasible.

#### Finish inspector

Summary only:

- total reps,
- total duration,
- average pace,
- recovery profile.

## Error and Feedback Design

Errors should be actionable and specific.

Bad:

```text
No feasible solution.
```

Good:

```text
160 reps in 20:00 requires 4.8s/rep at your level if you keep 8 reps/set and 30s reset.
Try removing the reset, lowering reps, or choosing 10 reps/set.
```

When the system makes a recommendation, explain it in plain terms:

```text
Recommended 20 x 8 because it keeps each set near 1:00 and leaves 17s recovery.
```

## Implementation Boundaries

This design intentionally avoids adding manual pace/recovery overrides in normal mode.

Advanced overrides can exist later, but only after the automatic prescription is trustworthy.

## Tests Required

Solver tests:

- even `160 / 20:00` does not create one 160-rep set,
- unbroken `160 / 20:00 / 8 reps` creates 20 repeated 8-rep sets,
- candidate ranking prefers human work intervals,
- optional reset suggestions only appear when feasible,
- explicit rests remain `PlanStep :rest`, not set recovery.

LiveView tests:

- graph renders the recommended prescription,
- clicking block opens one stable inspector,
- editing reps/set reruns solver and keeps inspector stable,
- clicking edge adds rest with clear feedback,
- impossible edits show actionable feedback.

## Acceptance Criteria

- A user can enter 20:00 / 160 / even and see a human-friendly repeated set/block prescription.
- A user can enter 20:00 / 160 / unbroken / 8 reps/set and see 20 x 8 with computed auto recovery.
- The graph is understandable without opening the inspector.
- The inspector edits the selected graph item with no card explosion or layout jump.
- Pace and recovery are auto by default and explained, not manually required.
- Solver feedback teaches the user what constraint is failing.
