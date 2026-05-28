# Session Segment + Flow FSM Design

## Problem

The current client runner FSM treats warmup and workout as one combined timeline. That leaks session-domain concepts into the generic runner logic:

- warmup duration must be subtracted from workout progress and timer calculations
- warmup and main rep counts live in the same runner state
- completion payload construction knows about `{warmup, main}`
- a finished warmup cannot naturally stop and wait for the user before the real workout begins

The desired model is that warmup and workout are both runnable plan segments. The segment runner should not know what a segment represents. Session-specific piping decides what to do after each segment finishes.

## Target user flow

```text
Warmup?
  Skip -> workout countdown -> workout -> logger
  Yes  -> warmup countdown -> warmup -> Ready for workout? -> workout countdown -> workout -> logger
```

Each segment owns its own countdown, timer, progress, visible rep counter, rep accounting, display commands, and final result. Warmup progress and rep count reset when the workout segment starts; the workout segment does not inherit visible progress or reps from warmup.

## Architecture

Split the client runtime into two explicit FSM layers.

### `session_segment_fsm.mjs`

Generic FSM for running one segment timeline.

Input:

```js
{
  timeline,
  blockCount
}
```

States:

```text
idle
countdown
countdown_paused
running
paused
done
```

Responsibilities:

- countdown transitions
- running tick and animation-frame scheduling
- pause/resume and visibility clock adjustment
- per-segment rep accounting
- per-segment display command derivation
- per-segment visible rep total updates
- beep command derivation
- completion of one segment

It must not contain these names or concepts:

- `warmup`
- `main`
- `workoutDurationSec`
- `warmupEndSec`
- final session payload shape

Final command:

```js
{ type: "segmentDone", result: { burpeeCountDone, durationSec } }
```

### `session_flow_fsm.mjs`

Session orchestration FSM. It owns the meaning of each segment.

States:

```text
warmup_prompt
warmup_countdown
warmup_running
warmup_done_prompt
workout_countdown
workout_running
workout_done
```

Responsibilities:

- decide whether warmup is skipped
- derive/start the warmup segment from client-owned plan data
- start the warmup segment
- store the warmup segment result
- show the `Ready for workout?` prompt
- start the workout segment with a fresh countdown
- store the workout segment result
- emit the final `session_complete` payload

Final payload remains compatible with the current LiveView:

```js
{
  warmup: {
    burpee_count_done,
    duration_sec
  },
  main: {
    burpee_count_done,
    duration_sec
  }
}
```

If warmup is skipped, the flow FSM uses a zero warmup result.

### `session_hook.js`

The hook becomes glue between browser events, server events, the flow FSM, and the segment FSM.

It owns:

- DOM event delegation
- server push/pull events
- instances of flow FSM, segment FSM, renderer, audio runtime, and wake-lock runtime
- command routing

It must not calculate:

- warmup duration
- workout duration
- progress math
- final payload shape
- whether the current segment is warmup or workout

## Command boundaries

Segment commands are generic and rendered the same for warmup and workout:

- `renderProgressBar`
- `renderTimer`
- `renderBlockLabel`
- `enterWorkPhase`
- `enterRestPhase`
- `renderWorkRepProgress`
- `renderRestProgress`
- `playLeadBeep`
- `playRepBeep`
- `scheduleAnimationFrame`
- `cancelAnimationFrame`
- `segmentDone`

Flow commands are session-specific:

- `pushWarmupRequested`
- `startSegment`
- `showWarmupDonePrompt`
- `pushSessionStarted`
- `pushSessionComplete`

## Testing requirements

### Segment FSM tests

- countdown transitions to running
- running tick displays progress/timer using only the segment duration
- visible rep total is segment-local and resets for each `SEGMENT_READY`
- segment completion emits `segmentDone`
- pause/resume preserves elapsed time
- visibility hidden/visible preserves elapsed time
- rep accounting completes the final rep at rest/end boundaries
- beep commands fire once per rep/rest countdown boundary

### Flow FSM tests

- skipping warmup starts the workout segment
- accepting warmup requests the warmup timeline
- receiving warmup starts the warmup segment
- warmup segment completion stores warmup result and shows the ready prompt
- ready prompt starts the workout segment with a fresh countdown
- workout segment completion emits the final `session_complete` payload

### Integration checks

- existing LiveView `session_complete` payload parsing continues to pass
- warmup request still returns a warmup timeline
- runner remains client-owned with `phx-update="ignore"`

## Non-goals

- No database schema changes
- No separate persisted `mood_before` / `mood_after`
- No XState or external FSM dependency
- No server-driven timer updates

## Success criteria

- Warmup and workout are executed by the same generic segment FSM.
- The segment FSM contains no warmup/workout domain leakage.
- Warmup completion pauses at a `Ready for workout?` prompt.
- Starting the workout uses a fresh countdown.
- Workout completion opens the existing session logger.
- `npm --prefix assets test`, `mix assets.build`, `mix test test/burpee_trainer_web/live/session_live_test.exs`, and `mix precommit` pass.
