# Gesture-Controlled Camera Setup, Warmup, and Start Design

**Date:** 2026-07-23
**Status:** Approved
**Scope:** Hands-free confirmation for the tracked-session pre-workout flow (camera readiness, warmup choice, workout start); removal of dead server-side warmup/mood overlay code

## Context

The pre-workout flow is entirely owned by a client-side state machine, `session_flow_fsm.mjs`, driven from `session_hook.js`. On mount, the server pushes a `session_ready` event; the client flow immediately renders its own prompts into a single `#start-overlay` div (created/repainted by JS, living inside the `phx-update="ignore"` `#session-runner-client` region) in this sequence:

1. **"Track your workout?"** (`showCapturePrompt`, `#capture-tracked-btn` / `#capture-timed-btn`) — mode selection. No camera/pose tracking exists yet at this point, so this screen has to stay a manual tap. **Out of scope for this change.**
2. **Camera setup** (only if tracked mode chosen) — `camera_setup_panel/1`, server-rendered inside `session_live.ex`, containing `#camera-setup-start-btn` (disabled until `capture_setup_state == :ready`) and `#camera-setup-timed-btn` ("Use timer instead"). Wired via plain click listeners in `session_hook.js` (`onCameraSetupStart`, `onCameraSetupTimed`).
3. **"Warm up first?"** (`showWarmupPrompt`, client-JS-rendered `#warmup-yes-btn` / `#warmup-skip-btn`) — distinct from a separate, unreachable server-rendered warmup prompt (see Dead Code below).
4. **"Ready when you are" / "Warmup complete"** (`showWorkoutStartPrompt`, client-JS-rendered `#workout-ready-btn`, "Start workout") — the prompt that actually starts the workout countdown via `WORKOUT_READY`.

The camera-setup button (step 2) is the most acute problem: the phone typically sits on a stand or floor during setup, and reaching to tap the button moves the body out of frame, dropping `capture_setup_state` back to `:arming` and re-disabling the button before the tap registers. This makes tracked-session start unreliable in practice.

### Dead code discovered during design

`session_live.ex` also contains a **second, server-rendered** warmup/mood overlay (`tap_to_start_overlay/1`, rendered inside `session_runner` when `@phase == :idle`), with its own `#warmup-yes-btn`/`#warmup-skip-btn` and a "How do you feel?" (Tired/OK/Hyped) mood picker firing `phx-click="session_started" phx-value-mood={...}`.

This overlay is **unreachable in real usage**:

- It lives inside the same `phx-update="ignore"` region as the client-owned `#start-overlay`. `session_flow_fsm.mjs`'s `SESSION_READY` handler fires `showCapturePrompt()` almost immediately after mount, which calls `overlay.replaceChildren()` on the very same `#start-overlay` element — wiping out the server-rendered warmup/mood markup before a user could plausibly interact with it.
- `session_started` (the only handler that reads `mood` and flips server `phase` to `:running`) is **never pushed from any JS code** — confirmed by grepping the entire `assets/` tree. Its only caller is the dead `phx-click="session_started"` button.
- Consequently `phase` never actually becomes `:running` in production, `warmup_asked` never flips server-side, and pre-workout mood is never actually collected, despite the markup's clear intent.
- `@phase` is matched with `case @phase do :not_runnable -> ... :done -> ... phase when phase in [:idle, :running] -> ... end` (`session_live.ex:531`) — `:idle` and `:running` render identically, and nothing else in the module reads `@phase` to distinguish them. `:not_runnable` is likewise matched but never assigned (a separate, pre-existing dead branch, left untouched — out of scope here).

This dead code is being deleted as part of this change, since it's directly adjacent to what's being built and leaving it would mean two divergent implementations of "ask about warmup" existing side by side.

## Goals

1. Eliminate the manual tap on camera setup — the most acute reliability problem (reaching for the phone knocks the pose out of frame).
2. Confirm camera setup automatically once tracking is stably ready, without requiring the user to touch the device.
3. Let a raised-hand gesture confirm each step faster than waiting on an auto-timer, without needing to touch the device.
4. Add the same hands-free gesture pattern to the real, client-owned "Warm up first?" and "Start workout" prompts.
5. Delete the dead server-rendered warmup/mood overlay (`tap_to_start_overlay`), its `session_started`/`mood`/`warmup_asked` plumbing, and collapse the now-meaningless `:idle`/`:running` phase distinction.
6. Preserve `SessionHook`/the flow FSM as sole authority for session phase and timeline progression — gestures only fire the same events the removed buttons used to fire.
7. Leave timer-mode (`capture_mode: :timed`) sessions unaffected — no `PoseTracker` is mounted for them, so no gesture detection applies.

## Non-goals

- Gesture control for "Track your workout?" (step 1) or "Use timer instead" — both stay manual taps; step 1 has no pose tracking running yet, and "Use timer instead" is the deliberate escape hatch.
- Gesture control for the post-workout completion panel (mood, tags, pause/abort controls) — untouched, and remains the only place mood is actually collected after this change.
- Removing the `mood` field, schema, or completion-panel mood picker.
- New pose landmarks, detector changes, or changes to rep-counting/readiness classification logic.
- A generalized gesture-recognition framework — this is a single gesture (raised wrist) reused with different hold-duration thresholds.
- Touching the pre-existing `:not_runnable` dead branch — unrelated, out of scope.

## Current flow → new flow

**Before (tracked-mode path):**

```
Track your workout? (tap, out of scope, unchanged)
  → Camera setup (tap, unreliable — reaching for phone loses pose)
  → Warm up first? (tap: Yes/Skip)
  → [warmup runs or is skipped]
  → Ready when you are / Warmup complete (tap: Start workout)
  → countdown
```

**After (tracked-mode path):**

```
Track your workout? (tap, unchanged)
  → Camera setup (auto-timer OR gesture)
  → Warm up first? (gesture=Yes / timeout=Skip)
  → [warmup runs or is skipped]
  → Ready when you are / Warmup complete (gesture, longer hold)
  → countdown
```

Timer-mode path is entirely unchanged at every step.

## Step-by-step behavior

### 1. Camera setup ready

- Once `capture_setup_state` reaches `:ready` (server assign, driven by `tracker_readiness` events), two triggers race to confirm; whichever fires first wins:
  - **Auto-timer:** 1.5s of continuously stable `:ready`/`:optimal` state.
  - **Gesture:** either wrist landmark held above its corresponding shoulder landmark for ~1s of consecutive sampled frames.
- If readiness drops back to `:arming` before either trigger fires, both the auto-timer and the gesture hold-streak reset. Neither trigger fires early or leaves a partial credit.
- On confirm: same effect as the current button — hides the camera preview, pushes `camera_setup_started` to the server, dispatches `CAMERA_SETUP_READY` to the flow FSM (the body of today's `onCameraSetupStart`).
- The manual `#camera-setup-start-btn` is deleted from `camera_setup_panel/1`. `#camera-setup-timed-btn` ("Use timer instead") is unchanged.

### 2. Warm up first? (Yes/Skip)

- Once `showWarmupPrompt` has rendered (client-JS prompt, `mode: "warmup_prompt"` in the flow FSM):
  - **Gesture (Yes):** raised wrist above shoulder held ~1s → fires the same path as today's `#warmup-yes-btn` click (`onWarmupYes` → `WARMUP_READY`).
  - **Timeout (Skip):** no qualifying gesture within ~4s of the prompt appearing → fires the same path as today's `#warmup-skip-btn` click (`onWarmupSkip` → `WARMUP_SKIP`).
- This step only applies when `capture_mode === "tracked"` (only then is `PoseTracker` mounted and producing pose samples). Timer-mode sessions keep the existing tap buttons unchanged — `showWarmupPrompt` markup is shared between both modes, only the gesture/timeout wiring is conditional.
- The `#warmup-yes-btn`/`#warmup-skip-btn` buttons are hidden (not removed from the DOM structure) when `capture_mode === "tracked"`, so the hands-free framing isn't undercut by a visible tappable alternative; timer-mode leaves them visible and tappable as today.

### 3. Start workout

- Once `showWorkoutStartPrompt` has rendered (either via `showWarmupDonePrompt` or `showWorkoutReadyPrompt`, both call the shared helper):
  - **Gesture:** raised wrist above shoulder held ~2s (longer than the other two steps, since this starts the actual clock) → fires the same path as today's `#workout-ready-btn` click (`onWorkoutReady` → `WORKOUT_READY`).
- Timer-mode sessions keep the manual `#workout-ready-btn` tap, unchanged. For tracked sessions the button is hidden — gestures are the intended hands-free path, and showing a tappable button alongside a "don't touch the phone" flow would undermine that framing.

## Dead code removal (`session_live.ex`)

- Delete `tap_to_start_overlay/1` entirely, its call site (`session_runner`'s `<%= if @phase == :idle do %>...<% end %>` block), and its `attr(:warmup_asked, :boolean, required: true)`.
- Delete `handle_event("session_started", ...)` — nothing else needs to push this event once the overlay that fired it is gone.
- Delete the `@mood_options` module attribute usage from this overlay (the completion panel's own copy at line ~851 is separate and stays — it's a different, still-reachable screen).
- Delete `assign(:warmup_asked, false)` at mount and the `warmup_asked={@warmup_asked}` prop threading through `session_runner`.
- Collapse the `case @phase do phase when phase in [:idle, :running] -> ...` branch to a single `:running -> ...` branch (or equivalent single match), since `:idle` is assigned at mount but nothing ever meaningfully observes it as distinct from `:running` once the dead code is gone. `assign(:phase, :idle)` at mount becomes `assign(:phase, :running)`. The `:not_runnable` and `:done` branches are untouched.
- `assign(:mood, nil)` at mount is unchanged — still consumed by the completion panel, which remains the only place mood is set (via its own separate `set_mood` handler, untouched).

## Client-side changes

### New module: `assets/js/hooks/pose_start_gesture.mjs`

Pure, streak-based detector mirroring `pose_readiness.mjs`'s shape (no DOM, testable in isolation):

- Input: current gesture state (`{ streak }`) + a `sample` (same shape consumed by `pose_readiness.mjs`, i.e. `sample.keypoints.{left,right}_{wrist,shoulder}`) + a `holdFramesRequired` threshold.
- Logic: gesture condition is `left_wrist.y < left_shoulder.y` OR `right_wrist.y < right_shoulder.y` (normalized image coords, smaller `y` = higher on screen), both points passing the same visibility check `pose_readiness.mjs` already uses (`score >= MIN_SCORE`, finite, in `[0,1]`).
- Streak resets to 0 on any frame where the condition is false (losing pose visibility or lowering the arm both count as "false" — no partial credit banked across gaps).
- At 15fps (`POSE_FPS` in `pose_sampler.mjs`): ~1s hold = 15 frames, ~2s hold = 30 frames. Call sites pass the frame count, not a raw duration — the module has no notion of wall-clock time.
- Returns `{ streak, satisfied }`; call sites compare `satisfied` transitioning false→true to fire exactly once.

### `pose_tracker_impl.mjs`

- Alongside the existing readiness-transition block in `loop()` (~line 181-191):
  - Maintains one active gesture-detector state at a time, parameterized by which step is currently armed (passed in from the hook, since only `session_hook.js`/the flow FSM knows which prompt is showing).
  - On `satisfied` transitioning to true, dispatches a local custom event `pose-tracker:gesture-confirm` the same way `pose-tracker:readiness` is dispatched today (`dispatchLocal`).
  - Also owns the 1.5s camera-setup auto-timer: started/cleared on `:ready`/`:optimal` transitions, dispatching the same `pose-tracker:gesture-confirm` event if it elapses before being cleared. Auto-timer and gesture are equivalent triggers by design (either confirms the step), so they share one event name — call sites never need to distinguish which one fired.
  - Warmup-step's ~4s no-gesture timeout lives here too, using the same timer pattern, dispatching a `pose-tracker:gesture-timeout` local event distinct from confirm.
- `createPoseTracker`'s returned object gains a new `armStep({ step, holdFramesRequired })` method (alongside `mounted`/`destroyed`), but — critically — `SessionHook` (`#burpee-session`) and `PoseTracker` (`#pose-tracker`) are **separate LiveView hooks with no shared JS object**; they only communicate via DOM `CustomEvent`s dispatched on `#pose-tracker` (the existing pattern used by `resetPoseTracker()`: `this.el.querySelector("#pose-tracker")?.dispatchEvent(new CustomEvent("pose-tracker:reset"))`) and `pose-tracker:*` events bubbled back up to `#burpee-session` (the existing pattern used by `onPoseTrackerReadiness` etc.). Arming therefore works the same way: `session_hook.js` dispatches a `pose-tracker:arm` custom event with `detail: { step, holdFramesRequired }` (or `{ step: null }` to disarm) on `#pose-tracker`; `pose_tracker_impl.mjs`'s `mountedHook()` adds a listener for it (alongside its existing `pose-tracker:finish`/`pose-tracker:reset` listeners) that updates the tracker's internal armed-step state, consumed inside `loop()`.

### `session_hook.js`

- Deletes the `camera-setup-start-btn` click-dispatch entry entirely (button removed from markup).
- For `warmup-yes-btn`/`warmup-skip-btn`/`workout-ready-btn`: click-dispatch stays (timer-mode still uses it), but a new `pose-tracker:gesture-confirm` / `pose-tracker:gesture-timeout` listener pair is added on `#burpee-session` (alongside the existing `pose-tracker:rep`/`pose-tracker:status`/`pose-tracker:readiness` listeners added in `mounted()`), calling the same `onWarmupYes`/`onWarmupSkip`/`onWorkoutReady` methods the clicks call today.
- A helper (e.g. `armPoseTrackerStep(step, holdFramesRequired)`) dispatches the `pose-tracker:arm` custom event on `#pose-tracker`, called whenever `runFlowCommand` shows a step that should accept a gesture (`showCameraSetupPrompt` → arm `"camera_setup"`; `showWarmupPrompt` → arm `"warmup"`; `showWorkoutStartPrompt`/`showWorkoutReadyPrompt`/`showWarmupDonePrompt` → arm `"workout_start"`), and disarmed (`armPoseTrackerStep(null)`) when leaving that step (i.e. at the start of each `show*Prompt` method, before arming the new one, so exactly one step is ever armed at a time).
- Timer-mode (`this.flow.captureMode !== "tracked"`) sessions never call `armPoseTrackerStep` (guarded by `if (this.flow.captureMode === "tracked")`), so their existing button click wiring is the only thing that ever fires for them — this only changes behavior for tracked sessions. This guard also naturally handles the case where `#pose-tracker` doesn't exist in the DOM at all (timer-mode never mounts it), since the helper no-ops when the querySelector finds nothing.
- `showWarmupPrompt` and `showWorkoutStartPrompt`: the `#warmup-yes-btn`/`#warmup-skip-btn`/`#workout-ready-btn` elements are hidden (e.g. `display: none` via a class) when `this.flow.captureMode === "tracked"`, visible otherwise.

## Safety / UX guards

- Each armed step disarms itself the instant it fires (`armStep` transitions to a new step or `null`), preventing double-fire between gesture and auto-timer/timeout racing.
- Losing pose visibility or lowering the arm mid-hold resets that step's streak to 0 — no partial credit persists across a gap.
- Auto-timer and no-gesture-timeout are cleared immediately when the underlying readiness/prompt state changes out from under them (e.g. `:ready` → `:arming` cancels the camera-setup auto-timer; leaving the warmup prompt cancels its timeout).
- "Use timer instead" and "Track your workout?" remain manual taps only, in both server and client code — never gesture-armed.

## Testing

- `pose_start_gesture.mjs`: pure unit tests mirroring `pose_readiness_test.mjs`'s style — streak accumulation, reset on visibility loss, reset on arm lowering, `satisfied` transition timing at the configured `holdFramesRequired`.
- `pose_tracker_impl.mjs`: extend existing hook-flow/impl tests to cover `armStep` wiring, auto-timer firing and cancellation, no-gesture-timeout firing and cancellation, and that `pose-tracker:gesture-confirm`/`pose-tracker:gesture-timeout` dispatch exactly once per arm cycle.
- `session_hook_flow_test.mjs`: cover that gesture-confirm/timeout events route to the same outcomes as the corresponding button clicks (`camera_setup_started` push + `CAMERA_SETUP_READY`, `WARMUP_READY`/`WARMUP_SKIP` flow transitions, `WORKOUT_READY` flow transition), and that timer-mode sessions are unaffected (no `armStep` calls, buttons still present and clickable).
- `session_live_test.exs` (new file — none currently exists for this LiveView): cover that `tap_to_start_overlay`/`session_started`/mood-picker markup and handlers are gone, `phase` starts at `:running`, and the camera-setup panel no longer renders a start button.
- Manual Firefox verification (per existing Task 8 pattern in the pose-tracking-observer plan): confirm camera-setup auto-confirms without touching the phone, confirm warmup Yes gesture and Skip timeout both work, confirm Start-workout gesture requires the longer hold and doesn't fire early off the Yes-gesture's momentum, confirm timer-mode session still works entirely by tapping as before.
