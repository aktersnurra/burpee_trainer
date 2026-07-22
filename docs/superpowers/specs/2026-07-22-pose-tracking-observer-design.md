# Pose Tracking Observer Design

**Date:** 2026-07-22  
**Status:** Approved  
**Scope:** Optional camera-backed rep counting and cadence capture for tracked workout sessions

## Context

BurpeeTrainer already mounts a BlazePose-backed `PoseTracker`, extracts pose samples, detects burpee-like movement cycles, emits rep timestamps, stores pose-trace chunks, and persists tracked-session cadence at completion. The missing piece is a safe session boundary:

- `pose_tracker_impl.mjs` starts its timestamp epoch when the detector becomes ready, before the workout countdown and possibly before warmup;
- each detected `"rep"` is pushed to LiveView, where `SessionLive.handle_event("rep", ...)` intentionally ignores it;
- tracked completion persists `cadence_ms`, but those timestamps are relative to camera initialization rather than the authoritative workout clock;
- `SessionHook` remains the correct owner of count-in, cadence, pause, visibility adjustment, segment progression, and completion;
- `data-target-pace-sec` is already rendered on `#pose-tracker`, but no client code consumes it;
- production live tracking currently uses the simple closeness-based counter, while the HMM, candidate extractor, and template matcher are wired only into `pose_debug.js`.

The current camera-start gate is also incomplete. The setup action can be invoked while the detector is still arming, and detector initialization alone does not prove that a usable person is visible.

## Video evidence

The referenced video, `https://www.youtube.com/watch?v=FMcvfyq0N0s`, supports a deliberately limited first version:

- **03:39–03:47:** automatic rep counting is described as a backup when the athlete loses count;
- **03:47–04:06:** recorded reps may later support form recommendations;
- **04:10–04:20:** advanced assistance remains optional.

The video provides product intent, not an implementation architecture. Its transcription is stored at:

`/tmp/youtube-transcript-FMcvfyq0N0s/transcript.srt`

Transcription confidence is medium because the fallback Whisper transcription may contain minor wording or timestamp drift.

## Goals

1. Make the tracked camera path a reliable backup counter and cadence recorder.
2. Preserve `SessionHook` and the segment FSM as the sole authorities for workout time and progression.
3. Prevent setup, warmup, pause, rest, hidden-tab, and post-completion movement from contaminating main-workout cadence.
4. Ensure the pose network and a stable core pose are available before enabling the tracked-session start action.
5. Allow cropped feet without blocking the workout.
6. Degrade to the existing timer-derived completion path whenever tracking cannot be trusted.
7. Collect trustworthy cadence data for later pace feedback without adding live pace UI in this version.

## Non-goals

- Camera-driven cadence, rep progression, rest timing, or workout completion
- Live pace UI, audio pace coaching, or adaptive timing
- Form correction or technique grading
- Production use of the debug-only HMM/template decoder
- Automatic reconciliation between multiple rep detectors
- Runner visual redesign
- A new persistence schema when existing `cadence_ms` and `target_pace_sec` fields suffice

## Core ownership rule

The camera is a fallible observer. It may report measurements, but it must never dispatch segment transitions or alter session timing.

`SessionHook` remains authoritative for:

- the exact main-workout start;
- pause and resume;
- hidden-tab elapsed-time adjustment;
- current timeline event;
- workout duration;
- timer-derived prescribed progress;
- normal and early completion.

The pose tracker remains authoritative only for:

- camera and detector lifecycle;
- pose samples and confidence;
- detector phase state;
- candidate rep events;
- capture-trace emission.

A new pure observer validates and records candidate rep events using timestamps supplied from the authoritative session clock.

## Architecture

### `pose_readiness.mjs`

Add a pure readiness evaluator over existing pose feature frames.

It returns one of:

- `not_ready` — inference is unavailable or core geometry is insufficient;
- `ready` — core body geometry is stable enough to attempt backup counting;
- `optimal` — lower-body visibility and framing should provide better accuracy.

`ready` is the hard start requirement. `optimal` is guidance only.

### `pose_tracking_observer.mjs`

Add a pure state machine with explicit state:

- lifecycle: `idle | observing | degraded | finished`;
- detector status: `initializing | live | lost`;
- accepted main-workout cadence timestamps;
- last detector index;
- last accepted timestamp;
- sticky degradation reason;
- readiness quality at workout start.

The observer accepts already-authoritative elapsed milliseconds. It does not call `performance.now()`, maintain a second pause clock, read DOM, or dispatch LiveView events.

### `PoseTracker`

Keep inference and candidate detection inside `pose_tracker_impl.mjs`.

It emits bubbling local events from `#pose-tracker`:

- `pose-tracker:rep` — detector index and diagnostic confidence/quality only;
- `pose-tracker:status` — `live` or `lost` after debouncing;
- `pose-tracker:readiness` — debounced `not_ready | ready | optimal` setup state.

It accepts local control events:

- `pose-tracker:reset` — clears detector phase and rep-counter state;
- existing `pose-tracker:finish` — completes capture with cadence supplied by the session observer.

Per-rep server pushes are removed. The existing completion push remains the persistence boundary.

### `SessionHook`

`SessionHook` listens for bubbling tracker events on its stable `#burpee-session` root, so the listener survives LiveView inserting or replacing the tracker subtree.

On a candidate rep it:

1. confirms the active segment is `workout`;
2. confirms segment mode is `running`;
3. confirms the current timeline event returned by `currentFrame(...)` is `work`;
4. obtains elapsed time from the pause-adjusted segment clock;
5. sends that elapsed timestamp to the pure observer;
6. does not update the renderer or segment FSM.

At main-workout `COUNTDOWN_DONE`, it resets both detector and observer before accepting any reps.

On pause, visibility restoration, or tracking recovery, it resets detector phase before accepting new candidates. This prevents movement observed across an untrusted gap from completing a half-observed rep.

At completion it chooses one of two existing paths:

- trusted observer result: pass authoritative `cadence_ms` in `pose-tracker:finish` and retain tracked completion;
- absent or degraded observer result: call the unchanged timer-derived `session_complete` path.

## Pose-network readiness gate

### What “valid pose” means

The gate verifies trackability, not exercise correctness. BlazePose landmarks can establish that usable body geometry is visible; they cannot by themselves certify good burpee form.

The existing feature frame already provides `poseConfidence`, `visibleFraction`, `isOccluded`, regional confidence scores, body bounding-box dimensions, and normalized geometry. Add a direct shoulder score if needed rather than inferring shoulder visibility from a broad upper-body average.

### Hard requirements

Before enabling **Start tracked session**:

1. camera playback has started;
2. BlazePose detector creation succeeded;
3. the inference loop has produced recent samples;
4. exactly one primary pose is being tracked;
5. shoulders and hips have usable bilateral confidence;
6. sufficient torso/lower-body geometry exists to produce a stable movement signal;
7. core readiness remains valid for roughly 0.5 seconds at the existing 15 FPS sampling rate.

Use hysteresis so a single weak frame does not flicker the control between enabled and disabled.

### Initial readiness thresholds

The first implementation uses explicit conservative defaults based on the feature extractor's existing visibility threshold:

- one detected pose;
- overall pose confidence at least `0.5`;
- left and right shoulder scores at least `0.5`;
- left and right hip scores at least `0.5`;
- at least one knee score at least `0.5`;
- visible landmark fraction at least `0.35`;
- finite shoulder, hip, and qualifying-knee coordinates inside the normalized frame;
- at least eight consecutive qualifying samples at the existing 15 FPS sampling rate before entering `ready`.

After entering `ready`, require three consecutive non-qualifying samples before returning to `not_ready`. This prevents flicker without hiding sustained pose loss. Recorded setup traces must cover full-body and cropped-feet framing before these constants ship; adjustments remain confined to `pose_readiness.mjs` and do not change session behavior.

`optimal` additionally requires bilateral knees plus at least one confident ankle and stronger visible coverage. It never changes whether Start is enabled.

### Feet are optional

Knees, ankles, feet, generous margins, and full head-to-foot framing improve quality but do not block start.

A user with cropped feet may enter `ready` rather than `optimal`. The setup may show restrained guidance such as “Tracking ready · wider framing improves accuracy,” but the start action remains available.

### Start control behavior

- `not_ready`: disable the start action and describe the current requirement;
- `ready`: enable start;
- `optimal`: enable start and show normal “Camera ready” copy;
- initialization failure or bounded timeout: offer timer mode;
- the click handler must re-check readiness locally so a stale DOM patch cannot bypass the gate.

Once a session starts, later landmark loss never blocks, pauses, or ends the workout. It only makes the observer result ineligible to prefill completion.

## Candidate-rep acceptance

A candidate rep is accepted only when all conditions hold:

- observer lifecycle is `observing`;
- detector status is live;
- active segment is the main workout;
- segment mode is running;
- current timeline event kind is `work`;
- timestamp is a non-negative integer;
- timestamp is monotonic and not duplicated;
- detector index is strictly increasing;
- timestamp does not exceed total main-workout duration.

A `work` event includes both active movement and its intra-rep recovery. Explicit between-set `rest` events are excluded.

The existing detector refractory rule remains the first duplicate defense. The observer independently enforces monotonicity and index uniqueness at the integration boundary.

## Trust and degradation

Degradation is sticky for the main workout. Once degraded, the observer may retain diagnostic samples, but its count cannot prefill the completion form.

Degradation reasons include:

- tracker not live at main-workout start;
- confidence/pose status becomes lost after start;
- malformed, duplicate, decreasing, or out-of-duration timestamp;
- bridge initialization failure;
- finish without a valid observer lifecycle.

Cropped feet alone are not a degradation reason when the core-pose readiness contract remains satisfied.

A future version may replace the all-or-nothing policy with measured coverage windows. The first version intentionally prefers false fallback over a falsely authoritative count.

## User experience

### Setup

The current setup panel remains. Its start action is genuinely disabled until core-pose readiness is stable. Missing feet produce optional framing guidance, not a block.

### During the workout

No additional visible element is introduced:

- the timer-owned top-left prescribed count remains unchanged;
- no camera count competes with it;
- no live pace appears;
- no tracking loss overlay interrupts the athlete;
- camera failure cannot change audio, fills, count-in, rest, or completion timing.

### Completion

- trusted tracking prefills the existing editable rep field and persists cadence;
- the editable actual total is the single dominant headline;
- directly beneath it, show `of N planned` as quiet immutable context;
- show `Counted by camera` as a separate tertiary provenance line;
- keep the planned target visible while the actual total is being edited;
- if the athlete changes the detected total, use honest provenance such as `Edited · camera counted N`;
- degraded tracking uses the timer-derived completion result and replaces camera provenance with `Camera view was interrupted · Check the total`;
- manual correction remains final authority.

Do not duplicate the same detected count in a separate tracked-review section. Preserve the existing completion metadata and controls below the summary: duration, mood, editable reps, editable minutes, tags, notes, and Save session. The tracking treatment changes only the summary hierarchy; it must not remove or hide that metadata.

## Pace data

Persist accepted pause-adjusted timestamps now. Do not expose live pace yet.

This enables later calculations such as:

- latest rep interval;
- rolling median interval;
- actual-versus-target pace;
- recovery consistency;
- detection disagreement against offline trace decoding.

The already-rendered `data-target-pace-sec` remains unused in the first release rather than motivating unvalidated feedback.

## Failure behavior

- Camera permission/model initialization failure: offer timer mode.
- Model ready but no stable core pose: keep tracked start disabled and explain framing.
- Feet cropped with stable core pose: allow start with quality guidance.
- Tracker lost after start: mark observer degraded, reset detection on recovery, continue workout.
- Tracker element absent at finish: use timer completion.
- Invalid tracked finish payload: use timer completion rather than switching the session to an error state.
- LiveView disconnect/reconnect: session timing behavior remains unchanged; tracking cannot become authoritative through reconnection.

## Testing strategy

### Pure readiness tests

- model initialized without a pose remains `not_ready`;
- stable shoulders/hips and sufficient core geometry become `ready`;
- cropped feet can still become `ready`;
- fuller lower-body coverage becomes `optimal`;
- unstable single frames do not enable start;
- hysteresis prevents readiness flicker;
- multiple/ambiguous poses remain `not_ready`.

### Rep-counter tests

Add deterministic synthetic coverage for the currently untested live counter:

- standing → down → standing emits exactly one rep;
- low-confidence samples emit none;
- refractory-window movement does not double count;
- reset clears setup/warmup phase and timestamps.

### Observer tests

- main-work candidates receive monotonic authoritative timestamps;
- count-in, paused, explicit-rest, hidden, and completed states reject candidates;
- intra-rep recovery within a `work` event accepts a valid completion;
- duplicate indices and decreasing timestamps degrade the result;
- cropped feet without core-pose loss do not degrade the result;
- any live-to-lost transition after start makes the final result untrusted;
- trusted finish returns cadence; degraded finish selects fallback.

### Hook-flow tests

- tracked start cannot occur before readiness;
- main `COUNTDOWN_DONE` resets detector and observer;
- warmup detections never enter main cadence;
- candidate reps never dispatch segment transitions or renderer updates;
- pause/resume and visibility recovery reset detector phase;
- trusted completion sends observer cadence through the existing tracker finish path;
- degraded completion uses the existing timer payload unchanged;
- timed mode remains unchanged.

### LiveView tests

- start action is disabled while arming/not ready and enabled after debounced readiness;
- initialization failure offers timer mode;
- trusted completion prefills detected reps and persists cadence;
- degraded completion keeps timer-derived reps and shows restrained review guidance;
- the completion rep input remains editable.

### Manual browser verification

- verify setup with full-body and cropped-feet framing;
- verify camera model cannot be bypassed while loading;
- verify camera loss/recovery does not alter workout timing or runner DOM;
- verify pause, explicit rest, and hidden-tab movement do not create accepted reps;
- verify trusted and degraded completion paths;
- verify portrait and 640×360 layout remains unchanged during the workout.

## Expected file map

Create:

- `assets/js/hooks/pose_readiness.mjs`
- `assets/js/hooks/pose_readiness_test.mjs`
- `assets/js/hooks/pose_tracking_observer.mjs`
- `assets/js/hooks/pose_tracking_observer_test.mjs`
- focused `pose_rep_counter` test coverage

Modify:

- `assets/js/hooks/pose_features.mjs`
- `assets/js/hooks/pose_tracker_impl.mjs`
- `assets/js/hooks/session_hook.js`
- `assets/js/hooks/session_hook_flow_test.mjs`
- `lib/burpee_trainer_web/live/session_live.ex`
- `test/burpee_trainer_web/live/app_flow_test.exs`

Do not modify the session display model, renderer, cadence program, or segment transition semantics unless verification exposes an unavoidable defect.

## Decision summary

- Tracking role: backup only.
- Integration: local observer using the authoritative `SessionHook` clock.
- Start gate: pose network plus stable core-pose trackability.
- Feet: accuracy bonus, never a hard start requirement.
- Live workout UI: unchanged.
- Completion: option A hierarchy is approved—one editable actual headline, quiet `of N planned` context, camera provenance, and all existing duration/mood/reps/minutes/tags/notes metadata preserved; degraded tracking falls back to timer total.
- Pace: timestamps stored now, feedback deferred.
- Camera authority: never controls workout progression.
