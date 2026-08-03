# Event-Driven Coach and Compiled Workout Design

**Status:** Approved

## Goal

Make BurpeeTrainer a calm training instrument: Home shows one persisted, verified workout and one concise coach comment. Creating or adjusting a workout uses natural language only. The LLM authors the readable work structure; deterministic code derives pace, cadence, recovery, and the immutable execution program.

This is a replacement of the existing multi-path planner/editor, not an LLM layer added beside it.

## Product posture

- **Home is present tense:** one workout and one primary Start action.
- **The coach is event-driven:** it is not a daily feed and does not regenerate on page load.
- **Creation is conversational but bounded:** the user describes a workout; the app displays a compiled result, never a chat transcript as the product.
- **Execution is deterministic and offline-capable:** no model or network request occurs after a workout starts.
- **The user owns execution:** only the user can Start or Save.

## Coach events

Persist a new `CoachRecommendation` only after one of these events:

| Event | Purpose |
| --- | --- |
| Monday at 05:00 local time | Open the week with the first recommended workout. |
| Workout saved | Recalculate the next recommendation from what actually happened. |
| Saturday at 05:00 with zero completed weekly minutes | Offer a feasible catch-up path. |
| Sunday at 05:00 with zero completed weekly minutes | Offer distinct final-week guidance or a feasible catch-up option. |

Home renders the most recent persisted recommendation unchanged. Visiting or refreshing Home does not create a new comment or workout.

Partial-week escalation is intentionally out of scope. The weekend events react only to zero completed weekly minutes.

## Coach context and deterministic policy

The model receives structured facts, never unrestricted raw history:

```text
trigger event
weekly completed minutes and per-type counts
active type-specific goals and deadlines
weekly target: 80 minutes
preferred weekly rhythm: 6-count → Navy Seal → 6-count → Navy Seal
current capacity and max permitted unbroken set size by type
last 16 completed sessions as normalized training facts
last completed workout and outcome
```

`current_best_20(type)` is the best normalized 20-minute result for that type within the current 16-session window. It is not an all-time personal best.

App-owned policies are hard constraints:

- Standard automatic workouts are 20 minutes.
- A 40-minute workout is available only after the user explicitly requests it. Its challenging target is `1.5 × current_best_20(type)`.
- An 80-minute workout is available only as a feasible catch-up option.
- The weekly target and type rhythm are deterministic facts, not instructions the model may override.
- A recommendation may change one meaningful training dimension at a time.

The deterministic target planner supplies the type, duration, total target, capacity envelope, and allowed session category. The model may choose a readable set configuration within that envelope and write the coach comment.

## First-principles workout model

```text
Workout
└── Block*
    └── Set*
        └── Rep*
```

- **Rep:** movement time and interval timing in the compiled execution.
- **Set:** a counted run of reps.
- **Block:** a readable repeated motif of one or two set sizes.
- **Workout:** ordered blocks within a fixed duration.

Blocks are the authoring concept. Pace, cadence, normal recovery, reset recovery, and exact event timestamps are compiled concepts.

## LLM workout source DSL

The LLM returns a versioned structured response from free text. It does not receive or produce Elixir structs, plan rows, executable events, pace, cadence, or recovery placement.

### Unbroken source

```json
{
  "version": 1,
  "kind": "unbroken",
  "burpee_type": "six_count",
  "duration_sec": 1200,
  "blocks": [
    {"repeat": 5, "motif": [8]},
    {"repeat": 5, "motif": [7]},
    {"repeat": 5, "motif": [7, 6]}
  ]
}
```

This maps directly to the solver's canonical `BlockSpec` representation. The resolver expands blocks and derives total reps. The blocks are exact: compilation must not reorder, split, merge, or improve them.

### Even source

```json
{
  "version": 1,
  "kind": "even",
  "burpee_type": "navy_seal",
  "duration_sec": 1200,
  "target_reps": 80
}
```

Even pacing is a continuous rep stream. The compiler derives movement pace and cadence; it accepts no LLM-authored blocks.

### Deliberately absent fields

```text
front_loaded / back_loaded / load_shape
pace bias
movement pace
cadence
normal recovery
reset recovery
explicit rest placement
execution events
plan rows or timeline edits
```

For a new or adjusted workout, the app sends the structured source through one replacement operation:

```text
replace_draft_source(draft_id?, source)
  -> compiled preview
  | clarification_needed(question, choices)
  | infeasible(reason, permitted adjustments)
```

The LLM sends a complete replacement source rather than patches. If the request is insufficient or conflicts with the target envelope, it asks one clear question. Nothing partial is saved.

## Compilation contract

```text
user free text
→ LLM structured source + coach comment
→ parse and validate DSL
→ derive PlanSolver.Input
→ PlanSolver derives pace, cadence, and recovery
→ canonical Execution
→ immutable ExecutionProgram
→ persist CoachRecommendation or draft preview
```

For unbroken sources, the resolver expands blocks, derives total reps, and provides the current max permitted unbroken set size. The solver verifies the exact structure and derives only timing and recovery. For even sources, the supplied target reps and duration determine the continuous cadence calculation.

A compiled program is accepted only if it satisfies total reps, exact duration, type-specific pace bounds, legal recovery boundaries, and the active session policy. The model may never start, save, or directly persist an executable workout.

## Home and creation flow

```text
Coach event
→ deterministic target envelope
→ LLM source and comment
→ compile and verify
→ persist recommendation

Home
→ persisted recommendation
→ Start workout
→ Adjust

Adjust
→ short free-text brief
→ full replacement source
→ compile and preview
→ Start
```

Home is intentionally sparse:

```text
Today

Navy Seal · 20 min
Keep the alternating rhythm. This is session two of four.

[ Start workout ]
Adjust · Why this?
```

- **Start workout** is the only primary action.
- **Adjust** is the only authoring surface; there is no manual block, pace, cadence, recovery, timeline, lock, copy, or rebalance editor.
- **Why this?** reveals one factual app-derived reason.
- The coach comment is one or two grounded sentences, generated and stored only at coach events.

## Bloat removal

The new workflow has one live planner source and one compiler path. Delete rather than preserve parallel ways to express the same workout:

```text
load_shape and front/back-loaded controls
pace_bias controls
block_pattern as public editor/API state
manual pace overrides in creation flows
manual recovery and timeline-rest controls
manual block lock/copy/rebalance controls
PlanEditor’s parallel source-to-plan path
legacy multi-phase workout-creator UI
```

`BlockSpec{repeat, motif}` is the sole human-authored unbroken structure. Old source data may be read only at a migration boundary for existing plans; it must never leak into the new UI or LLM contract. Existing persisted `ExecutionProgram`s remain immutable and runnable.

## Shared OpenRouter transport

`vibe-open-router` is a standalone Git library used by both Tore and BurpeeTrainer. It owns only server-side OpenRouter chat-completions transport: `Req` execution, caller-supplied attribution headers, timeouts, normalized provider errors, and a typed client configuration.

It does not own models, prompts, tool schemas, JSON response interpretation, event scheduling, persistence, or any product workflow. Tore retains its image-generation and OpenAI-wire concerns; BurpeeTrainer owns coach prompting and workout-source parsing.

## LLM boundary and failure behavior

The model produces a source and comment after an event or adjustment. The app validates and compiles before persistence. Provenance records the event kind, structured context hash, source, compiled program, validation result, model version, and prompt version.

| Failure | User-visible result |
| --- | --- |
| Model call fails | Show the latest valid recommendation. If none exists, offer a deterministic baseline or brief entry point. |
| Source is invalid | Ask one focused clarification; do not save a draft. |
| Source cannot compile | Explain the hard conflict and present only allowed adjustments. |
| Active workout loses network | No effect; the client-authoritative runtime continues. |

## Verification criteria

- Coach notes are generated only by the four defined event kinds.
- Reopening Home without a new event never changes the recommendation or comment.
- The coach receives structured facts from the last 16 sessions.
- Unbroken LLM sources use exact `BlockSpec`-compatible blocks.
- The compiler, not the LLM, derives pace, cadence, recovery, and execution events.
- A 40-minute workout requires an explicit user request and uses `1.5 × current_best_20(type)`.
- An 80-minute workout is feasible catch-up only.
- The UI exposes no manual planner/editor controls after the LLM source is compiled.
- Every accepted source compiles before persistence.
- The active workout remains usable without model or network access.
