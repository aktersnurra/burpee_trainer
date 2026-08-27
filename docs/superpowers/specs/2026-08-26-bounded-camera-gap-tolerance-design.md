# Pushup Occlusion-Tolerant Burpee HSMM Design

**Status:** approved for implementation

## Problem

The retained three-rep physical-camera run completed with zero actual reps because the current HSMM discards a partial path whenever one frame is unusable. The user deliberately tested camera loss by leaving frame and also observed loss during pushups. Its derived trace has 1.23 s, 1.33 s, and 1.52 s losses after the pushup phase begins. Simulating one unusable observation for each retained gap yields zero reps under the current HSMM.

The third path reaches rising but its best standing score is 0.479, narrowly missing the final 0.48 threshold.

## Goals

- Use clear phase names: `standing → lowering → pushup → rising`.
- Preserve a strictly established `pushup` candidate across unusable observations with **no duration cap**. Navy Seals can perform multiple pushups, so a timeout would be arbitrary.
- Keep all transitions ordered, preserve strong out-of-order resets, and never fabricate a rep.
- Change only the final `rising → standing` threshold from 0.48 to **0.47**.
- Retain the 0.72 forward threshold, 900 ms rep refractory interval, and the 1.1 body-span gate before `pushup → rising`.
- Keep raw landmarks private. Tests use synthetic or derived macro features only.

## Non-goals

- Do not alter pose-model selection, reporting, trace upload, lifecycle rules, scheduled pacing, or server-side validation.
- Do not make all phases gap-tolerant.
- Do not add a phase or repetition duration timeout.

## State model

The HSMM state vocabulary is:

| Previous term | New term |
| --- | --- |
| `upright` | `standing` |
| `lowering_to_floor` | `lowering` |
| `floor_work` | `pushup` |
| `returning_from_floor` | `rising` |

For an unusable frame:

- If the current phase is `pushup`, return the state unchanged. This preserves the established ordered candidate, cadence, and refractory timestamp through occlusion or out-of-frame time without deriving a transition from absent evidence.
- Otherwise reset the incomplete candidate to `standing` while preserving accepted cadence and the refractory timestamp.

For a usable frame:

- Score only the current phase and its next ordered phase.
- A strong emission for any non-current/non-next phase resets immediately, including after pushup occlusion.
- `pushup → rising` still needs its existing body-span gate and the 0.72 forward threshold.
- `rising → standing` alone uses 0.47. That transition records a rep only outside the existing refractory interval.

A candidate therefore cannot be counted during absence. It is counted only after fresh ordered rising and standing evidence.

## Verification

- A single long sequence of derived pushup frames—including unusable frames—counts once after fresh rising and standing evidence.
- An unusable frame before pushup still resets an incomplete path.
- A usable strong out-of-order observation after pushup occlusion resets immediately.
- A final standing score of at least 0.47 counts; a score below 0.47 does not.
- Existing body-span, out-of-order, landmark-gate, slow-return, refractory, user-labeled, and SessionHook handoff fixtures remain green.
- The retained three-rep trace simulation produces three reps when its observed gaps are represented as unusable frames.
- Full asset tests and `mix precommit` pass.

## Acceptance limitation

The retained trace omits raw unusable frames, so it cannot prove live detector behavior by itself. It does prove the model semantics under the explicit fault-injection assumption. A later physical-camera run remains the final acceptance check; no raw landmarks are exported.