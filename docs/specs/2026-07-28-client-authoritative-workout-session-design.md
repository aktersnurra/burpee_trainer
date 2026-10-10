# Client-Authoritative Workout Session Design

**Date:** 2026-07-28
**Status:** Approved
**Scope:** Replace split client/server pre-workout ownership with a lean client-authoritative runtime through completion review; make final Save and deferred pose-trace upload the only network boundaries
**Source review:** `.rpiv/artifacts/reviews/2026-07-28_workout-session-redesign.md`

## Context

The current runner already keeps countdowns, segment timing, pause/visibility adjustment, rep progress, audio, and high-frequency rendering in JavaScript. Recent camera and gesture changes left pre-workout ownership split across `SessionHook`, `PoseTracker`, `session_flow_fsm.mjs`, and `SessionLive`:

- the client can enter camera setup before the server creates a pose-capture run;
- camera gesture confirmation can advance the client before readiness while the server rejects the same transition;
- detector exceptions can mark tracking lost on the server while the local observer remains trusted;
- warmup gesture arms can remain active and restart the warmup;
- edited camera totals retain incompatible cadence and cannot be saved;
- pose chunks are uploaded every few seconds during exercise;
- completion review waits for a LiveView round trip.

The workout must remain responsive on poor or unavailable networks. Camera tracking is a fallible backup observer. The client timer/cadence plan is authoritative in every session, whether or not the camera is enabled.

## Goals

1. Make camera choice, camera readiness, warmup choice, workout start, active timing, pause/resume, completion, and editable completion review client-authoritative.
2. Permit the whole workout and completion review to run without network access or LiveView acknowledgements.
3. Keep the client timer/cadence plan authoritative when camera or pose estimation fails.
4. Preserve strict hands-free tracked-mode warmup and start with explicit, room-readable instructions and robust readiness behavior.
5. Make final Save idempotent and recoverable without losing the completed result.
6. Buffer pose traces locally during exercise and upload them only after the session result is safely persisted.
7. Preserve the minimal, distance-readable runner presentation and distinguish intra-rep recovery from between-set rest.
8. Resolve the verified findings in the source review without changing unrelated application behavior.

## Non-goals

- Full offline synchronization of the final session without an explicit Save retry.
- Network requests, telemetry pushes, or pose-trace uploads during pre-workout or active exercise.
- Camera-driven workout timing, progression, rest, or completion.
- Live pace coaching, form grading, or camera counts on the active runner.
- Changing global zoom or hidden-scrollbar behavior.
- Changing pose-trace disclosure or retention in this personal-use application.
- Replacing the existing execution-program, segment-FSM, or timer/cadence semantics.
- Adding a third-party state-management, storage, or upload dependency.

## Core ownership rule

The live session has one authority: the client runtime.

### Client owns

- camera choice and startup;
- camera readiness and framing state;
- raised-hand gesture arming, confirmation, timeout, and consumption;
- warmup choice and warmup/workout orchestration;
- count-ins, clocks, audio, pause/resume, and visibility adjustment;
- timer-derived rep progress and completion;
- tracking trust/degradation;
- immediate completion review and edits;
- local completion draft and pose-trace queue.

### Server owns

- initial authenticated plan/program bootstrap;
- final validation and idempotent session persistence;
- structured Save errors;
- authenticated, idempotent ingestion of deferred pose traces;
- normal post-save statistics/history rendering.

No server event may advance or block a pre-workout or active-workout state.

## Client state model

Extend the pure client flow state machine so it is authoritative through completion review:

```text
capture_choice
├─ camera_starting
│  ├─ camera_error
│  │  ├─ retry → camera_starting
│  │  └─ continue_without_camera → warmup_choice
│  └─ camera_setup
│     ├─ continue_without_camera → warmup_choice
│     └─ confirmed → warmup_choice
└─ continue_without_camera → warmup_choice

warmup_choice
├─ gesture_confirm → warmup_running
└─ gesture_timeout → workout_ready

warmup_running
└─ segment_done → workout_ready

workout_ready
└─ gesture_confirm/manual_non_camera_start → workout_running

workout_running
├─ camera_failure → workout_running with tracking degraded
├─ finish_early → completion_review
└─ segment_done → completion_review

completion_review
├─ edit → completion_review
├─ save_failed → completion_review
└─ save_succeeded → persisted
```

The state includes:

- `captureMode`: `camera | no_camera`;
- `cameraState`: `idle | starting | arming | ready | lost | failed`;
- `trackingTrust`: `disabled | arming | observing | degraded | finished`;
- the currently armed gesture step and its hold threshold;
- warmup and workout results;
- completion draft and Save status;
- stable `client_session_id` and execution-program identity.

Events that do not match the current state are ignored. Gesture and timeout events carry their armed step so stale events cannot affect a later prompt.

## Stable DOM and rendering

`SessionLive` renders the complete session surface once:

- camera choice panel;
- camera loading/error panel;
- camera setup/preview panel;
- warmup choice panel;
- workout-ready panel;
- runner panel;
- pause actions;
- completion review form;
- one stable live status region.

The client-owned surface remains under `phx-update="ignore"`. `SessionHook` toggles stable panels and fills values; it no longer creates/replaces `#start-overlay` markup. This preserves immediate transitions, stable focus targets, Tailwind-visible classes, and deterministic test selectors.

The initial HTML embeds the serialized execution program, plan identity, program hash, and `client_session_id` on the hook root. `SessionHook` boots synchronously from those values instead of waiting for a post-mount `session_ready` push.

`PoseTracker` is mounted lazily: mount registers local handlers, while a local `pose-tracker:start` command requests camera/model resources only after **Yes, use camera**. Camera startup may fetch same-origin static model/WASM assets; that resource load is not a session-state API dependency, and failure transitions locally to camera-unavailable recovery.

## Camera choice and terminology

Use the exact approved copy:

```text
Track burpees with the camera?
The workout timer runs either way. Camera tracking adds a backup rep count.

[Yes, use camera]  [No, continue]
```

Do not use “timer mode” or “Use timer” in user-facing copy. The timer/cadence plan runs in every session.

All later camera escape actions use **Continue without camera**.

## Camera startup and setup

### Starting

After **Yes, use camera**, the client enters `camera_starting` and locally starts camera/model resources.

Copy:

```text
Starting camera
```

No pose-capture database row is created and no server event is required.

### Startup failure

Copy:

```text
Camera unavailable
Nothing has started.

[Try again]  [Continue without camera]
```

Retry tears down any partial resources before starting again. Continuing without camera enters the same client timer/cadence flow without tracking.

### Setup readiness

Arming copy:

```text
Step into frame
Keep shoulders, hips, and one knee visible.
```

Ready copy:

```text
Camera ready
Hold one hand up or stay still.
```

Camera confirmation is valid only when the local readiness state is `ready | optimal`. The 1.5-second auto-confirm timer starts only while readiness is continuously valid. The raised-hand gesture is also readiness-gated. Losing readiness resets both timer and gesture streak.

## Strict hands-free warmup and start

### Warmup choice

Tracked copy:

```text
Warm up first?
Raise one hand to warm up.
Skipping in 4
```

- raised hand means Yes;
- visible countdown expiration means Skip;
- readiness loss pauses the countdown and changes the helper to **Step into frame**;
- entering either branch consumes/disarms the warmup step before changing state;
- no tracked-mode Warm up/Skip buttons are shown.

Without-camera sessions render manual **Warm up** and **Skip warmup** actions.

### Workout start

Tracked copy:

```text
Ready when you are
Hold one hand up to start.
```

- the workout has no auto-start timeout;
- readiness loss disables gesture acceptance and changes the helper to **Step into frame**;
- **Continue without camera** remains the explicit escape;
- accepting start consumes/disarms the step before the countdown begins.

Without-camera sessions render a manual **Start workout** action.

After a completed warmup, use the distinct title **Warmup complete** and corresponding helper rather than discarding the supplied copy.

## Active-workout failure contract

Camera tracking never controls the workout clock or progression.

Detector confidence loss, camera loss, and detector exceptions all use one local degradation transition:

1. clear `poseTrackerReady`;
2. cancel camera auto-confirm/gesture timers;
3. emit local lost status;
4. make observer degradation sticky;
5. stop or safely retry inference outside the session clock;
6. keep the workout timer/cadence, audio, progress, pause, and completion unchanged.

Once degraded, camera results cannot become trusted again during that workout. Completion uses timer-derived reps and duration with no camera cadence analytics.

No application API request, LiveView event, telemetry push, or trace upload occurs because of tracking status during exercise. Same-origin camera model/WASM asset loading is limited to camera startup and may fail without blocking the no-camera workout path.

## Intra-rep recovery and rest

The semantic states remain distinct:

- `work_active`: orange active movement fill;
- `work_recovery`: muted-blue full-screen recovery with centered bare seconds;
- `rest`: muted-blue set-rest field;
- `rest_count_in`: still, field-free final three-second count-in.

All blue rest screens, including `work_recovery`, use the same subtle breathing animation. The `is-work-recovery` class preserves recovery semantics without disabling that motion. Do not add active-workout labels, cards, or extra chrome.

## Client completion review

The final timer tick transitions immediately to the pre-rendered completion form.

The client fills:

- actual reps;
- planned reps;
- duration;
- camera provenance when applicable;
- mood, tags, and note;
- stable `client_session_id` and execution-program identity.

### Result sources

1. **Trusted and unchanged camera result**
   - camera reps may prefill actual reps;
   - cadence and pace analytics are eligible for persistence.

2. **Manually corrected camera result**
   - edited reps/duration are authoritative;
   - show **Edited · camera counted N**;
   - persist no cadence or pace analytics;
   - retain tracked capture mode so history reflects that camera tracking was used.

3. **Degraded or failed camera**
   - use timer-derived reps and duration;
   - persist no camera cadence analytics;
   - camera failure never interrupts completion.

The completion draft is written to IndexedDB before display and after each edit. Reloading the same session route restores the latest unsaved draft, including its original `client_session_id`.

Discard remains client-local before Save: after confirmation it stops camera resources, deletes the completion draft and buffered trace chunks, and navigates back to workouts without a server event.

## Final Save contract

Final Save is the first required network operation.

`SessionHook` submits the completion payload with `pushEvent` and receives a structured reply:

```text
ok:      {session_id, redirect_to}
invalid: {field_errors, global_errors}
error:   {message, retryable}
```

The server:

- scopes plan/program/session identity to the authenticated user;
- reuses existing `client_session_id` idempotency;
- independently compares actual values with the supplied detected camera result;
- discards cadence when the result was corrected or degraded;
- validates unchanged trusted cadence with the existing strict invariants;
- persists the workout before acknowledging success.

The client:

- retains the IndexedDB draft until success;
- renders field/global errors and focuses/announces the summary;
- allows safe retry after disconnect or timeout;
- deletes the completion draft only after persistence is acknowledged;
- queues buffered traces with the persisted session identity;
- navigates without waiting for trace upload.

## Local pose-trace buffering

Replace active-session `pose_capture_chunk` pushes with an IndexedDB-backed queue.

### During exercise

- the existing recorder still emits bounded chunks at its current interval;
- a separate queued writer stores chunks locally outside the inference/animation call stack;
- chunks are keyed by `client_session_id` and `chunk_index`;
- write failure degrades trace retention only and never tracking/timing;
- no upload request occurs.

### After Save

A small authenticated uploader drains queued chunks after the workout session exists:

- resolve the persisted session by authenticated user plus `client_session_id`;
- lazily create/link one pose-capture run;
- ingest bounded chunk batches;
- make chunk ingestion idempotent by run/session identity plus chunk index;
- retain failed batches in IndexedDB for retry on a later authenticated app visit;
- delete local chunks only after server acknowledgement.

The uploader runs independently of the session surface, so navigation cannot lose the queue. No third-party storage or queue dependency is added.

## Accessibility

- Every pre-workout and completion panel has a real heading.
- Panel transitions move focus to the new heading without scrolling the workout surface.
- One stable live region announces readiness, warmup timeout, count-in, pause/resume, tracking fallback, completion, and Save errors.
- Count-in announces **Workout starts in N**.
- Strict hands-free instructions are readable at workout distance.
- Completion inputs expose labels, invalid state, and associated error messages.
- Existing keyboard pause behavior and confirmed destructive actions remain.

## Error behavior

| Failure | User-visible outcome | Preserved state |
| --- | --- | --- |
| Camera/model startup fails | Camera unavailable; Try again / Continue without camera | Program and session choice |
| Readiness lost before start | Step into frame; timers/gesture streak pause/reset | Current prompt |
| Camera/detector fails during workout | No interruption; timer/cadence continues | Full workout clock and progress |
| IndexedDB trace write fails | No workout interruption; trace retention marked unavailable | Workout and completion |
| Save validation fails | Field/global errors; editable draft remains | Completion draft and client ID |
| Save network fails | Retryable Save state | Completion draft and trace queue |
| Trace upload fails | Background retry later | Persisted workout and local chunks |

## Expected implementation surface

Likely modifications:

- `lib/burpee_trainer_web/live/session_live.ex`
  - render stable client-owned panels/form;
  - remove active-session camera/readiness/chunk event authority;
  - return structured final-Save replies.
- `lib/burpee_trainer/workouts.ex`
  - explicit corrected/degraded tracked persistence semantics;
  - idempotent deferred trace ingestion.
- `lib/burpee_trainer/workouts/pose_capture_run.ex` and trace schema/migration as needed
  - enforce idempotent session/chunk identity.
- `lib/burpee_trainer_web/router.ex` plus a small authenticated upload boundary
  - accept deferred trace batches without coupling to a specific LiveView.
- `assets/js/hooks/session_flow_fsm.mjs`
  - own camera through completion-review states and stale-event guards.
- `assets/js/hooks/session_hook.js`
  - toggle stable DOM, run client flow, local completion, final Save/retry.
- `assets/js/hooks/pose_tracker_impl.mjs`
  - lazy start, readiness-gated gestures, unified local degradation, no active uploads.
- `assets/js/hooks/pose_capture_recorder.mjs`
  - emit chunks to a local writer rather than the network.
- new focused IndexedDB modules under `assets/js/hooks/`
  - completion draft store;
  - pose-trace queue/uploader.
- `assets/js/hooks/session_renderer.mjs` and `assets/css/app.css`
  - announcements and breathing blue rest/recovery states.
- focused JS and ExUnit flow tests.

The implementation plan may adjust exact file boundaries after targeted inspection, but it must preserve the ownership and network contracts above.

## Testing strategy

### Pure client state tests

- every legal pre-workout/workout/completion transition;
- stale gesture/timeout events ignored after arm consumption;
- camera gesture cannot confirm while not ready;
- warmup gesture cannot restart an active warmup;
- detector failure produces sticky degradation;
- no-camera and degraded paths retain timer-authoritative results;
- corrected camera result drops cadence eligibility.

### End-to-end JavaScript flow tests

- camera startup failure → retry and continue-without-camera;
- strict hands-free warmup Yes and visible timeout Skip;
- readiness loss pauses pre-workout gesture/timeout behavior;
- tracked start requires the longer hold;
- network disabled from mount through completion review;
- final tick counts the current frame before completion;
- camera failure during work does not alter clock/progress;
- completion review appears without a server event;
- reload restores unsaved completion;
- Save errors preserve draft and retry with the same client ID;
- trace chunks write locally and queue only after Save.

### Server/context tests

- final Save is idempotent by authenticated user plus `client_session_id`;
- unchanged trusted result validates and saves cadence;
- corrected/degraded result saves without cadence analytics;
- structured field/global errors are returned;
- deferred trace upload resolves only the current user’s session;
- duplicate chunk batches do not duplicate data;
- failed uploads do not alter the saved workout.

### LiveView/HTML tests

- stable panel/form IDs exist in the initial client-owned surface;
- no active-session event handler is required for readiness, gestures, reps, or chunks;
- tests use `has_element?/2` or LazyHTML, not raw HTML assertions;
- authenticated route/program scoping remains intact.

### Verification commands

- `cd assets && npm test`
- focused ExUnit files during implementation
- `mix precommit`
- `mix assets.build`

### Manual Firefox verification

- portrait and short-landscape geometry;
- distance legibility for camera, warmup, start, recovery, rest, and completion;
- strict hands-free gesture behavior;
- camera/model failure before and during workout;
- offline pre-workout/workout/completion review;
- reconnect and idempotent Save;
- navigation before trace upload completes, followed by successful retry.

## Acceptance criteria

1. No application API request, LiveView event, telemetry push, or trace upload is required from camera choice through completion review; optional same-origin camera assets may load during camera startup.
2. Poor or absent network cannot delay, pause, restart, or terminate a workout.
3. Camera/pose failure during exercise produces no visible interruption and uses timer-derived completion.
4. Camera gestures are readiness-gated, step-tagged, and consumed once.
5. Tracked prompts remain strict hands-free and explicitly explain gesture/timeout behavior.
6. Completion review appears immediately and survives reload until Save succeeds.
7. Corrected camera results save successfully without cadence analytics.
8. Final Save is idempotent and returns usable structured errors.
9. Pose traces are written locally during exercise and uploaded only after Save.
10. All blue rest screens breathe, including intra-rep recovery, while preserving distinct recovery semantics.
11. Focus/live-region behavior covers prompts, count-in, pause/resume, completion, and errors.
12. JavaScript tests, focused ExUnit, `mix precommit`, and `mix assets.build` pass.
