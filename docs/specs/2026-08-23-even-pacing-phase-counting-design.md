# Even-pacing phase-counting design

## Status

Approved in conversation on 2026-08-23; awaiting review of this written spec.

## Problem

During an even-paced workout, the runner must show a rep as complete when that rep's active ("go") interval ends. A following rest interval must not delay that visible progress. The last rep's active interval completes the workout immediately: there is no final rest.

Camera-confirmed reps are a separate fact. Missing, cropped, or low-confidence camera observations remain silent no-ops. The timer must never fabricate an actual rep.

> **Authoritative camera semantics — supersedes the silent-no-op wording above:** Follow the [Continuous HSMM Sequence Design](2026-08-24-continuous-hsmm-sequence-design.md). An unusable frame resets only an incomplete HSMM candidate and emits no rep; a strict ordered valid continuous sequence is required; there is no phase-duration cap; and the return-only `0.48` threshold applies only to `returning_from_floor → upright` after the strict prior phases. No camera path fabricates a rep.

The investigated unfinished session used logged/no-camera mode. It therefore has no capture run or pose trace to diagnose framing, and its displayed zero camera count cannot establish whether the person was in frame.

## User-visible behavior

For a three-rep even-paced workout:

1. The first active interval starts at `0/3`.
2. At the end of its active interval, scheduled pace progress becomes `1/3`.
3. Any rest before the next active interval retains `1/3`.
4. The final active interval changes scheduled pace progress to `3/3` and completes the workout immediately.

The UI must distinguish scheduled pace progress from camera-confirmed actual reps whenever camera tracking is active. A schedule tick never fabricates an actual rep.

## Design

### Separate facts

The session runner keeps two values:

- **Scheduled pace progress**: the number of configured active rep intervals that have completed. It drives the paced on-screen `n/target` progression.
- **Observed reps**: camera events accepted by the HSMM. They drive camera-derived actuals only when tracking finishes successfully.

No-camera workouts have no observed-rep value. Their report flow retains editable planned estimates rather than claiming timer progress as camera evidence.

### Timeline accounting

The segment FSM derives scheduled pace progress from the immutable timeline.

- Inside a work event, completed sub-intervals are `floor(phase_elapsed / sec_per_rep)`, bounded by that event's configured reps.
- Crossing from a work event into rest accounts any remaining work reps before entering rest.
- Rest events cannot increase scheduled pace progress.
- The terminal event must be work. When the final work interval completes, the FSM emits completion at that timestamp; it does not wait for or append rest.

The even solver already selects explicit-rest boundaries only before the final set. The compiler and runner will make that terminal-work invariant explicit and test it, so later changes cannot reintroduce a final rest.

### Completion and reporting

Completion results carry scheduled pace progress separately from detected camera reps. For completed camera tracking, `burpee_count_actual` comes only from detected reps. For no-camera or incomplete tracking, actual values remain unresolved and the existing resolver presents editable planned estimates. Duration remains schedule-derived, never wall-clock-derived.

## Scope

Included:

- Session segment FSM state, timeline accounting, and runner display commands.
- Completion-result mapping needed to keep schedule and camera facts distinct.
- Even-solver/compiler terminal-work invariant tests.
- Focused browser/harness evidence for active, rest, and final-active behavior.

Excluded:

- HSMM thresholds, landmark gates, fixture boundaries, camera calibration, or fallback detection.
- Retrospective reconstruction of sessions that did not run camera tracking.
- Automatic correction of a user's manually reported actual count.

## Verification

Tests must cover:

1. A completed active interval advances scheduled progress before its following rest begins.
2. Rest leaves scheduled progress unchanged.
3. The final active interval completes the session with no trailing rest delay.
4. A camera run with no accepted pose reps preserves zero observed actuals even while scheduled pace progress advances.
5. The even solver/compiler produces no final rest after the final set.
6. No-camera completion still routes through the resolver with editable estimated values.

Browser verification must show `0/3 → 1/3 → 1/3 during rest → 2/3 → 3/3 and complete`, and must explicitly identify scheduled progress separately from camera-confirmed reps.
