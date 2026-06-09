# Planner / Solver / UI Redesign Design

Date: 2026-06-11

## Goal

Redesign the workout planner as a phone-first recommendation surface that produces human, editable workout prescriptions. The solver should be good enough that most users only make small adjustments, rarely need advanced controls, and never see a configure-everything engineering page.

The target feel is closer to Flighty precision plus Things 3 restraint: calm, premium, direct, minimal text, excellent feedback, and fast editing.

## Architecture decisions

### Use “draft,” not “skeleton”

Use product language throughout the planner domain:

```text
Goal → Draft generation → Draft prescription → Compile / start session
```

Do not expose “skeleton” in module names, UI copy, or durable domain concepts. “Draft” matches the product experience: the solver proposes a workout draft that the user can tune.

### Redesign the planning data model

The current persisted workout model should not be treated as the planner’s native model. `WorkoutPlan`, `Block`, `Set`, and `PlanStep` are executable/session-oriented concepts. They are useful for playback, but they are too low-level and too ambiguous for draft generation.

The redesign should introduce a prescription-first planning model and then either compile to the existing execution model or replace the execution tables as part of a broader data-model overhaul.

The key separation is:

```text
Planning draft model  — user-facing prescription and solver state
Execution model       — machine-readable session playback
Session model         — actual performed workout and results
```

A block should not mean “whatever grouping the database needs.” A block/pattern exists only when it carries workout meaning.

### Keep fatigue optimization in mind

Fatigue minimization is not required for v1, but the solver should leave room for it as a future objective profile. Future solver objectives may include:

- balanced
- minimize fatigue
- maximize recovery
- finish strong

For v1, ranking can use heuristic quality costs. Later, fatigue can become another cost term based on cumulative intensity, recovery, reset placement, burpee type, and actual session outcomes.

### Use precise timing names

Domain names should be precise; UI labels can be friendlier.

Rename the current timing concepts conceptually as:

```text
sec_per_rep     → rep_interval_sec
sec_per_burpee  → burpee_duration_sec
```

Derived:

```text
micro_rest_sec = rep_interval_sec - burpee_duration_sec
```

UI may display `rep_interval_sec` as “pace,” but the domain should avoid fuzzy names like `pace` and `cadence` when storing solver facts.

## Product experience

The planner is a solver-first draft tuner:

```text
enter required goal → receive excellent prescription → maybe make one small adjustment → save
```

The required goal always includes:

- duration
- target reps
- burpee type
- style / pacing intent

The app produces one best draft as a vertical workout prescription timeline. The timeline is the workout prescription itself, not a database view or graph editor.

Default UI principles:

- low-control by default
- no noisy explanation paragraphs
- one obvious primary action: save/use draft
- quiet secondary action: regenerate/try another
- editing appears only in context
- advanced solver controls stay hidden

The user can tap a timeline item to make a small contextual adjustment. The solver reruns immediately, may improve the whole draft, and briefly highlights changed timeline items. Feedback appears only when useful.

## Pacing semantics

### Even pacing

Even pacing means rest is distributed between reps.

The intended execution feel is steady cadence:

```text
rep → small rest → rep → small rest → rep ...
```

Even pacing should be represented as readable time units, usually 1-minute or 2-minute units, not giant blocks.

Examples:

```text
Every 2:00 · 15 reps
Every 1:00 · 7–8 reps
10 rounds of [4, 3]
```

Rules:

- reps are paced across the interval
- micro-rest mostly lives between reps
- sets/blocks are readability units, not necessarily true unbroken efforts
- standalone reset rests may still be inserted around strategic points when useful
- never output one giant set or meaningless one-block wrapper for ordinary even pacing

### Unbroken

Unbroken means reps happen back-to-back inside a set, then the user rests after the set.

```text
8 reps continuous → rest → 8 reps continuous → rest
```

Unbroken requires a max reps per set input because that defines the upper bound of each intense work zone.

Rules:

- reps inside a set have no planned rest
- rest comes after the set
- optimize for useful longer rests
- work zones are more intense than even pacing
- never output one giant unbroken set unless explicitly allowed by the max set size

### Meaningful block patterns

A block only earns its existence when it describes a meaningful repeated pattern.

Use a block/interleaved pattern when:

- the burpee type or style benefits from alternating rep counts
- the pattern creates a better rhythm than flat units
- the repeated structure is easier to execute than isolated sets

Example:

```text
10 rounds of [4, 3]
```

This can mean the first set is denser/more intense and the second set leaves more recovery at the end. Do not create a block item merely to wrap a normal repeated set.

## Solver model

The solver should be a draft-generation pipeline, not a function that directly emits database blocks and sets.

Recommended pipeline:

```text
Goal
→ StyleProfile
→ DraftGenerator
→ DraftAllocator
→ DraftVerifier
→ DraftRanker
→ DraftPrescription
→ ExecutionCompiler
```

HiGHS/MILP remains reasonable, but only at the allocator layer. MILP should help choose counts, rest allocation, optional reset inclusion, pattern repeat counts, and exact duration/reps satisfaction from generated draft candidates. It should not be the product model and should not directly own UI/persistence shapes.

The editing model is:

```text
Required goal + user intent signals
→ solve
→ prescription timeline projection
→ save compiles to WorkoutPlan
```

The required goal is stable. The solver must not silently change duration, target reps, burpee type, or style unless the user explicitly accepts a repair that changes one of them.

Timeline edits are intent signals by default, not rigid constraints. For example:

- add a rest around a specific minute
- prefer smaller sets
- try a 2-minute unit
- try a pattern like `[4, 3]`
- make this rest longer/shorter

The solver may change nearby or global structure after an edit if that creates a better prescription. The UI should make these changes visible through subtle highlights, not a bureaucratic review step.

Hard constraints exist only behind advanced controls:

- lock this rest
- lock this block/item
- force max set size
- preserve exact pattern

## Human prescription rules

A mathematically exact plan is not acceptable if it is not human-readable.

The solver should strongly prefer:

- time-sized units for even pacing, especially 1–2 minute units
- bounded set sizes
- repeated patterns with simple vocabulary
- interleaved blocks only when they express a real alternating workload
- explicit rests at meaningful minute marks
- no single giant set/block unless explicitly requested

The solver should heavily penalize:

- one block containing all reps
- one set containing all reps
- dozens of tiny fragments with no human rhythm
- blocks that do not encode a meaningful pattern
- fake recovery inserted only to make the math look comfortable

## High-density behavior

At high density, such as `300 reps / 20:00`, normal comfort assumptions break down. The solver should not pretend there is meaningful recovery between every set.

Instead it should:

- keep units readable, such as 25-rep sets or dense per-minute units
- allow between-set rest to approach zero
- represent the workout honestly as dense continuous work
- avoid inventing tiny fake rests
- still avoid one giant unreadable set

Human-readable does not always mean comfortable. It means executable and legible.

## Strategic standalone rests

The solver should actively look for meaningful standalone reset rests in hard continuous efforts:

- first preferred reset around ~12 minutes
- optional late reset around ~17 minutes when feasible

Standalone rests are different from between-set or micro-rest. They are explicit timeline reset moments.

Example shape:

```text
0:00–12:00   dense work units
12:00        explicit reset
12:45–17:00  dense work units
17:00        optional reset if useful
17:30–20:00  finish
```

## Rest buffer rule

Standalone rests are not free time. When the solver adds an explicit rest, it must fund it by rebalancing work before and/or around it.

Adding a 45s reset at 12:00 may cause the solver to:

- reduce between-set rest before 12:00
- slightly increase pace before the reset
- restructure units before the reset
- adjust after the reset depending on density

The mental model is:

```text
work a bit harder → save a rest buffer → take explicit reset
```

The UI can explain this briefly:

```text
Added 45s reset · earlier sets tightened to fund it
```

## Duration rule

Duration is fixed, with only small execution/rounding tolerance.

- acceptable tolerance: about ±10s
- do not suggest extending duration as a repair
- if duration cannot be met, repair by changing structure, reps, rest, or pace instead

Invalid repair:

```text
Extend to 21:00
```

Valid repairs:

- add a reset funded by tighter work elsewhere
- reduce target reps
- switch to 2-minute units
- reduce reps/unit
- lower max reps/set
- remove an explicit lock
- try an interleaved pattern

## UI structure

The main planner is a vertical prescription timeline optimized for phone.

### Default surface

Show:

- compact required goal header: duration, reps, burpee type, style
- beautiful vertical prescription timeline
- one primary save/use action
- quiet regenerate/try-another action
- bottom feedback only when useful

Do not show by default:

- solver parameters
- lock controls
- split/remove controls
- manual pace controls
- dense editing panels
- technical validation details

### Timeline items

Use simple workout language, not planner jargon.

Item types:

- even time unit
- unbroken set group
- standalone rest
- meaningful block pattern only when warranted
- finish summary

Example even timeline:

```text
Every 2:00
15 navy seals
steady cadence

12:00
45s reset

Every 2:00
15 navy seals
finish steady
```

Example unbroken timeline:

```text
8 reps
then 42s rest

8 reps
then 42s rest

12:00
60s reset
```

### Editing

Editing should be shallow and contextual.

Tap a timeline item to reveal only the most likely adjustment:

- rest item: rest duration
- even pacing item: unit length or reps/unit
- unbroken item: max reps/set or rest after set
- block pattern: pattern only if the pattern is meaningful

Fast gestures may support quick changes:

- swipe/drag value chips
- tap plus/minus for precise adjustment

Advanced actions stay behind long press or more:

- lock item
- split section
- remove section
- reset to solver recommendation
- force pattern

If users need lots of manual editing to get a human plan, that is a solver failure, not a UX opportunity.

## Feedback and repair behavior

The planner should avoid hard errors where possible. Most problems should become repairable solver feedback.

Feasibility states:

1. Good
   - exact goal within tolerance
   - human-readable
   - safe/reasonable pace
   - no feedback needed

2. Adjusted
   - solver changed derived values or structure after an edit
   - changed timeline items briefly highlight
   - bottom bar may show a concise note

3. Tight
   - feasible, but near limits
   - bottom bar offers optional improvements

4. Infeasible
   - cannot satisfy required goal safely or exactly with current intent/constraints
   - keep draft visible
   - bottom bar offers concrete fixes

Feedback examples:

```text
Rest after sets adjusted to 38s
```

```text
Too dense after 12:00 · Try +30s reset or 14 reps/unit
```

```text
Changed to [4, 3] to keep navy seals even
```

```text
Added 45s reset · earlier sets tightened to fund it
```

No walls of explanation. No permanent red panels unless the plan truly cannot be saved.

## Data flow and boundaries

Separate four concerns:

```text
Goal form
→ Solver input
→ Solved prescription
→ Saved workout plan
```

### Goal form

Collects:

- duration
- target reps
- burpee type
- style
- style-specific required fields, such as max reps per set for unbroken

The goal form stays compact. Most defaults come from the solver.

### Solver input

Combines:

- required goal
- optional preference signals
- optional explicit advanced constraints

### Solved prescription

The solver returns a prescription, not just executable steps.

A prescription includes:

- timeline items
- total reps / duration / burpee type / style
- pace and rest calculations
- feasibility status
- changed-item metadata for UI highlights
- concise feedback when useful
- repair suggestions when tight or infeasible
- decision metadata for debugging and tests

### Planning draft model

The planning model is the source of truth while generating and tuning a prescription.

Candidate structs/modules:

- `BurpeeTrainer.Planning.Goal`
- `BurpeeTrainer.Planning.Draft`
- `BurpeeTrainer.Planning.DraftItem`
- `BurpeeTrainer.Planning.Solver`
- `BurpeeTrainer.Planning.Compiler`

A draft stores the user-facing prescription and solver state:

- goal snapshot
- status
- timeline items
- feedback
- repairs
- solver version
- generated/updated timestamps
- decision metadata

Draft item kinds should represent semantics directly:

- even time unit
- unbroken set group
- standalone rest
- meaningful pattern

### Execution model

Saving or starting a session compiles the draft prescription into machine-readable execution steps. This may compile into the current `WorkoutPlan` / `Block` / `Set` / `PlanStep` tables temporarily, but the implementation plan should evaluate whether those tables should be replaced or simplified.

A redesigned execution model could be flatter and more explicit:

- ordered execution steps
- step kind
- burpee count
- `rep_interval_sec`
- `burpee_duration_sec`
- explicit rest seconds
- source draft item id

The execution model should be optimized for playback and session running, not for solving.

### Session model

Workout sessions should reference the draft or execution-plan version used at start. This preserves what the user intended and allows future planned-vs-actual comparison.

Potential future session facts:

- actual reps
- actual duration
- completed steps
- perceived effort
- fatigue signals
- plan adherence

### Boundary rule

The LiveView should not own solver logic.

The LiveView should:

- collect goals and preferences
- render prescriptions
- send edits as intent signals
- save compiled results

The domain solver should:

- understand style semantics
- generate human prescriptions
- rebalance after edits
- validate feasibility
- produce repair suggestions
- compile to workout plan format

## Success criteria

### Solver examples

#### Even pacing never produces giant fake blocks

Input:

```text
20:00 · 150 reps · 6-count · even
```

Expected:

- generates 1-minute or 2-minute execution units
- no single 150-rep set
- no meaningless one-block wrapper

Acceptable shape:

```text
Every 2:00 · 15 reps
```

#### Unbroken requires max set size

Input:

```text
20:00 · 160 reps · standard · unbroken · max 8 reps/set
```

Expected:

- repeated unbroken sets no larger than 8 reps
- rest comes after sets
- useful longer rests are preferred
- no single 160-rep set

#### Interleaved blocks only when meaningful

Input:

```text
20:00 · 70 reps · navy seal · even/interleaved
```

Expected:

- can produce a meaningful pattern like `10 rounds of [4, 3]`
- block exists because alternating pattern improves rhythm
- flat repeated sets are not wrapped in fake blocks

#### High-density fallback stays legible

Input:

```text
20:00 · 300 reps · standard · even
```

Expected:

- groups work into readable units
- between-set rest may approach zero
- no fake recovery
- no one giant set

#### Standalone rest is funded

Input:

```text
20:00 · 160 reps · standard · even · add rest around 12:00
```

Expected:

- inserts meaningful explicit rest near 12:00
- keeps duration within ±10s
- funds rest by tightening pace/recovery/structure elsewhere
- feedback explains the funding briefly

### UI examples

- required goal header includes duration, reps, burpee type, and style
- vertical timeline is readable on phone
- default screen has no noisy explanatory paragraphs
- tap item reveals only contextual lightweight controls
- advanced controls stay hidden
- solver changes briefly highlight affected items
- bottom feedback bar appears only for useful changes, tightness, or infeasibility
- save compiles prescription to executable workout plan
