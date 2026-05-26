# Session Runner FSM Design

## Goal

Replace the implicit SessionHook runtime flags with an explicit finite state machine so timing, pauses, warmup, completion, and rep accounting are handled by named transitions instead of scattered `if` checks.

## Current Problem

The hook currently mixes several concerns in one mutable object:

- prompt flow (`warmup`, mood selection),
- countdown,
- running/paused clock,
- current timeline event,
- rep counting,
- audio beeps,
- direct DOM rendering,
- server pushes.

The result is fragile boundary behavior. Exact transitions, such as the final rep before rest or the final rep before workout completion, depend on animation-frame timing and mutable flags like `doneReps`, `lastEventType`, and `lastWorkEvent`.

## Design

Introduce a pure reducer-style FSM inside `assets/js/hooks/session_hook.js`.

### States

- `warmup_prompt`
- `mood_prompt`
- `countdown`
- `running`
- `paused`
- `completed`

State shape:

```js
{
  mode: "running",
  timeline: [],
  mainTimeline: [],
  blockCount: 0,
  mood: null,
  clock: {
    startTime: null,
    pauseTime: null,
    hiddenAt: null,
    elapsedSec: 0,
    totalDurationSec: 0,
    warmupEndSec: 0,
  },
  reps: {
    currentEventKey: null,
    doneInEvent: 0,
    mainDone: 0,
    warmupDone: 0,
  },
  countdown: {
    value: null,
    paused: false,
    stepStartedAt: null,
    stepElapsedMs: 0,
  }
}
```

### Events

- `SESSION_READY`
- `WARMUP_YES`
- `WARMUP_READY`
- `WARMUP_SKIP`
- `MOOD_SELECTED`
- `COUNTDOWN_TICK`
- `COUNTDOWN_DONE`
- `TICK`
- `PAUSE`
- `RESUME`
- `VISIBILITY_HIDDEN`
- `VISIBILITY_VISIBLE`
- `FINISH_EARLY`
- `WORKOUT_DONE`

### Commands

The reducer returns `{state, commands}`. Commands perform effects outside the reducer:

- `pushWarmupRequested`
- `pushSessionStarted`
- `pushSessionComplete`
- `startCountdownTimer`
- `startAnimationFrame`
- `cancelAnimationFrame`
- `renderPrompt`
- `renderCountdown`
- `renderRunningFrame`
- `playLeadBeep`
- `playRepBeep`
- `playCompletion`

## Rep Accounting Rule

Rep accounting happens in one pure helper:

```js
accountReps(previousFrame, nextFrame, reps) -> reps
```

Rules:

1. Warmup reps increment `warmupDone` only.
2. Main reps increment `mainDone` only.
3. The visible total is always `mainDone`.
4. When transitioning from a burpee event to rest, account all missing reps for the previous burpee event.
5. When transitioning from a burpee event to workout completion, account all missing reps for the previous burpee event.
6. Re-accounting an already finalized event is impossible because `currentEventKey` changes only through the reducer.

## Rendering Boundary

The LiveView server renders the shell once. The full runner subtree remains client-owned with `phx-update="ignore"`.

The hook owns these IDs during a session:

- `ring-svg`
- `flash-circle`
- `count`
- `down-word`
- `pause-icon`
- `total-done`
- `progress-fill`
- `time-left`
- `block-info`
- `start-overlay`

Server events remain limited to:

- initial `session_ready`,
- optional `warmup_ready`,
- final `session_complete`.

## Testing

Add pure JS tests for the reducer/helpers if a JS test runner exists. If not, create a small Node-based script under `assets/js/hooks/session_fsm_test.mjs` and run it from `npm test` or a documented command.

Test cases:

- warmup reps do not affect visible main total,
- final rep is counted when transitioning to rest,
- final rep is counted when workout completes,
- pause/resume preserves elapsed time,
- warmup skip starts main timeline only,
- finish early sends current main and warmup counts.

Keep existing LiveView tests for DOM shell and server persistence.

## Non-goals

- Do not add XState or another dependency in the first pass.
- Do not redesign visuals while changing state mechanics.
- Do not move high-frequency timing back to LiveView.
