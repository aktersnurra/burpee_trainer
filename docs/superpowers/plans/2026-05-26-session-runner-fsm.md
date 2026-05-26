# Session Runner FSM Implementation Plan

Goal: replace implicit SessionHook runtime flags with an explicit finite state machine and pure rep-accounting helpers.

## Task 1: Extract pure timeline and rep helpers

Files:

- `assets/js/hooks/session_fsm.js`
- `assets/js/hooks/session_fsm_test.mjs`
- `assets/package.json` if needed for a test script

Steps:

1. Create pure helpers:
   - `currentFrame(timeline, elapsedSec)`
   - `eventKey(event, index)`
   - `accountReps(previousFrame, nextFrame, reps)`
2. Write Node tests first for:
   - no count during warmup visible total,
   - final rep counted when next frame is rest,
   - final rep counted when next frame is `null` at workout end.
3. Run the JS tests and verify they fail before implementation, then pass.

## Task 2: Introduce reducer state shape

Files:

- `assets/js/hooks/session_fsm.js`
- `assets/js/hooks/session_fsm_test.mjs`

Steps:

1. Add `initialSessionState()`.
2. Add `transition(state, event)` returning `{state, commands}`.
3. Cover prompt/countdown/running/completed state changes only. Keep rendering side effects out.
4. Test:
   - `SESSION_READY` enters `warmup_prompt`,
   - `WARMUP_SKIP` enters `mood_prompt` with main timeline,
   - `WARMUP_READY` uses warmup + main timeline,
   - `MOOD_SELECTED` enters `countdown` and emits session-start command.

## Task 3: Wire SessionHook to the FSM incrementally

Files:

- `assets/js/hooks/session_hook.js`
- `assets/js/hooks/session_fsm.js`

Steps:

1. Import FSM helpers into `session_hook.js`.
2. Replace scattered timeline/rep flags with `this.fsm` state.
3. Keep existing rendering functions initially.
4. Make `tick()` dispatch `TICK` and render from returned state/commands.
5. Ensure `onComplete()` dispatches `WORKOUT_DONE` and sends the reducer's counted reps.
6. Run JS tests and `mix assets.build`.

## Task 4: Preserve LiveView shell and server contract

Files:

- `lib/burpee_trainer_web/live/session_live.ex`
- `test/burpee_trainer_web/live/session_live_test.exs`

Steps:

1. Keep `#session-runner-client phx-update="ignore"`.
2. Keep fixed ring dimensions unless a separate visual design is approved.
3. Keep server `session_complete` payload shape unchanged:
   - `main.burpee_count_done`
   - `main.duration_sec`
   - `warmup.burpee_count_done`
   - `warmup.duration_sec`
4. Run LiveView tests.

## Task 5: Final verification and push

Run:

```bash
node assets/js/hooks/session_fsm_test.mjs
mix assets.build
mix precommit
```

Commit:

```bash
jj describe -m "refactor(session): model runner as finite state machine"
jj new
jj bookmark set master -r @-
jj git push -b master
```

## Acceptance Criteria

- Warmup reps never affect visible total reps done.
- Final rep before rest is counted.
- Final rep at workout completion is counted.
- Runner remains client-owned.
- Existing session save behavior remains unchanged.
- `mix precommit` passes.
