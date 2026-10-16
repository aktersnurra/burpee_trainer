# Starting a workout with one tap: build plan

Spec: `docs/specs/2026-10-16-quick-start-design.md`. Each task is test first (red,
green), then `mix precommit` and `npm test --prefix assets`, then one jj change. Tasks 1–3
are one shippable change set: the toggles are useless until the session reads them, and
the session cannot drop its questions until the toggles exist.

## 1. Start choices (`assets/js/hooks/start_choices.mjs`)

- `readStartChoices(storage = globalThis.localStorage) :: {camera, warmup}` and
  `writeStartChoice(key, value, storage)`. Keys `burpee.start.camera`,
  `burpee.start.warmup`, stored as `"1"`/`"0"`. Missing, malformed, or a throwing storage:
  `{camera: false, warmup: true}`. Writes swallow storage errors.
- Tests (`start_choices_test.mjs`): defaults, round trip, malformed value, throwing
  storage on read and on write.

## 2. Home toggles

- `home_workout_components.ex`, `workspace/1` action row: a camera button before edit and
  a warmup button after new, both outside `home-expanded-action` so they show collapsed.
  IDs `home-start-camera`, `home-start-warmup`; `type="button"`, `aria-pressed="false"`
  server-side, `data-start-choice="camera" | "warmup"`, icons `hero-video-camera`,
  `hero-fire`, labels "Camera tracking", "Warmup". `phx-update="ignore"` on each so a
  patch does not reset the pressed state.
- Hook `HomeStartChoices` (`home_start_choices.mjs`) on the action row: on mount reads the
  choices and sets `aria-pressed`; a click flips it and writes. Registered in
  `app_bootstrap.js`.
- CSS in `adaptive_home.css`: pressed off is the muted ink with a struck-through line
  (`::after` diagonal), no colour change for on beyond the normal ink.
- Tests: LiveView test that both buttons render outside `#home-expansion` with
  `aria-pressed`, collapsed and expanded, and are absent while authoring; hook test with a
  fake element and storage for mount and toggle.

## 3. The session starts itself

FSM (`session_flow_fsm.mjs`):

- `SESSION_READY` carries `choices: {camera, warmup}` and moves to `starting` (no panel,
  no render beyond the runner's blank state).
- New `START`, only from `starting`: camera on → `camera_starting` as `CHOOSE_CAMERA`
  did; camera off → `beginAfterSetup` (below).
- `beginAfterSetup(state)`: warmup on → `startWarmup`; off → `startWorkout`. Used by
  `START` (camera off), `GESTURE_CONFIRM` on `camera_setup`, and
  `CONTINUE_WITHOUT_CAMERA`.
- `SEGMENT_DONE` for the warmup → `startWorkout` directly.
- `RESTORE_COMPLETION_DRAFT` accepted from `starting` (was `capture_choice`).
- `CONTINUE_WITHOUT_CAMERA` from `camera_starting`, `camera_error`, `camera_setup` only.
- Remove `capture_choice`, `warmup_choice`, `workout_ready`, `CHOOSE_*`, `WARMUP_*`,
  `WORKOUT_READY`, the `warmup` and `workout_start` gesture steps. `state.warmup` holds
  the choice.

Hook (`session_hook.js`):

- Boot: `SESSION_READY` with `readStartChoices()`; then `this.draftRestore.then(() =>
  dispatch START)` when the flow is still `starting`, so a finishing session reopens on
  its finish screen.
- `GESTURE_CONFIRM` and `CONTINUE_WITHOUT_CAMERA` carry the warmup timeline, as
  `handlePoseGestureConfirm` already does.
- Drop the warmup timeout machinery, `onWarmupYes/Skip`, `onWorkoutReady` and their click
  handlers.

Markup (`session_components.ex`, `session_live.ex`) and renderer:

- Delete `capture_choice/1`, `warmup_choice/1`, `workout_ready/1`.
- Merge `camera_status/1` into `camera_setup/1`: one panel `session-camera-setup` with the
  preview, a status line `#camera-setup-status` ("Starting camera", "Step into frame",
  "Hand up or hold still", "Camera unavailable"), retry (error only) and "Continue without
  camera". The failure detail stays. The sentence about shoulders,
  hips and knee goes.
- `renderFlowState`: `camera_starting`, `camera_error`, `camera_setup` → the one panel;
  `renderCameraSetup` sets the status line and retry visibility.

Tests:

- `session_flow_fsm_test.mjs`: the four rows of the spec's table, `START` before and after
  a draft restore, camera failure and retry, continue without camera from each camera
  mode with warmup on and off, warmup end goes straight to the workout.
- `session_hook_flow_test.mjs`: replace the capture/warmup/ready click paths with: boot
  with camera off reaches the workout countdown with no clicks; camera on reaches the
  camera panel; a stored draft opens the finish screen and never starts.
- `session_live_test.exs`, `app_flow_test.exs`: drop the removed panel IDs; assert the one
  camera panel.

## 4. Finishing with one tap

- `completion_review/1`: reps and seconds inputs become hidden by default; the count
  (`#session-actual-reps`) and duration (`#session-actual-duration`) become buttons
  (`aria-label` "Correct reps", "Correct time") that reveal their input and focus it.
- Note: a `hero-pencil` button `#completion-note-toggle` beside leave and save reveals the
  textarea; it starts revealed when a restored draft has a note.
- Mood unchanged.
- Hook: click handlers for the three reveals; `renderCompletionControls` keeps disabling
  the inputs while saving, revealed or not.
- Tests: hook flow test that saving untouched sends the counted reps and time; correcting
  the count reveals the input and the edit saves; a restored note shows the field.
  LiveView test that the inputs are in the form (so a no-JS submit still carries them)
  but hidden.

## Order

1 → 2 → 3 land together as one change set, 4 alone. Manual check on a phone after 3:
camera off, ▶ to first rep with no other tap; camera on, ▶, hand up, countdown.
