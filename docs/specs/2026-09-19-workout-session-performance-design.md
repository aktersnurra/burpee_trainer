# Workout Session Performance Design

## Goal

Reduce perceptible workout-session lag on an iPhone 11 in both manual and camera modes without changing workout behavior, camera tracking accuracy, the 15 FPS inference cadence, camera selection constraints, or the approved visual language.

## Scope

This work addresses verified client-side sources of unnecessary main-thread, layout, paint, allocation, and serialization work in the workout session.

Included:

- reduce redundant per-frame DOM queries and mutations;
- avoid duplicate timeline and rep calculations;
- move continuous visual effects toward compositor-friendly properties;
- eliminate repeated whole-buffer pose trace serialization;
- stop drawing the pose overlay when camera setup is not visible;
- suspend pose inference and trace capture while the session is paused;
- size the overlay canvas only when it has visible dimensions and keep it synchronized with visible size changes;
- add focused regression tests and run existing session verification.

Excluded until physical-device profiling demonstrates a need:

- reducing the 15 FPS pose inference cadence;
- changing MediaPipe model complexity;
- constraining camera resolution or acquisition frame rate;
- moving pose inference into a worker;
- changing workout timing, rep accounting, audio cues, tracking semantics, or visual design.

## Architecture

### Session rendering

`SessionRenderer` will retain references to frequently updated DOM nodes and the last values applied to them. Discrete values such as counts, timer strings, accessibility text, hidden state, and ARIA labels will only be written when their rendered value changes.

The animation loop will remain authoritative for elapsed time. Continuous per-rep progress will still update on animation frames, while discrete display state will be diffed. The session FSM will calculate the current timeline frame and rep state once per tick and pass those results into rendering rather than recomputing them in `SessionHook`.

The optimization must preserve skipped-frame catch-up behavior when the browser stalls or throttles animation callbacks.

### Visual effects

The blue breathing surface will use opacity between solid, absolutely positioned layers instead of animating the viewport background color. The visual timing and colors remain unchanged.

The orange per-rep fill will use one JS-owned compositor-friendly transform on a dedicated layer. The implementation must not combine a static Tailwind scale class with a dynamic transform because that previously made the fill invisible. Visual regression checks must confirm bottom-up fill, reset behavior, pause behavior, and reduced-motion behavior.

The DOWN cue will restart through the Web Animations API or an equivalent retained animation mechanism without reading layout geometry after style writes.

### Pose capture

Camera behavior remains front-camera, 15 FPS inference, and MediaPipe model complexity 1.

The tracker will distinguish three independent states:

- stream active;
- inference active;
- preview overlay visible.

Leaving camera setup hides and disables overlay drawing but does not stop active-workout inference. Pausing suspends inference and trace capture while preserving resources needed for a fast resume. Resuming resets temporal tracking state before sampling again so stale pre-pause motion cannot produce a rep. Stopping or destroying the tracker continues to release tracks and detector resources.

A visibility-aware canvas sizing path will ignore zero-sized measurements, size after camera setup becomes visible, and react to subsequent visible dimension changes. It will preserve the existing hook-local ownership and DOM structure.

### Pose trace recording

The recorder will maintain exact incremental encoded-byte accounting for the pending JSON payload. Each sample is encoded or measured once. The recorder will include wrapper, comma, and array overhead so emitted chunks continue to respect `MAX_TRACE_CHUNK_BYTES` exactly.

Chunk payload shape, indices, timestamps, diagnostics, three-second flush behavior, IndexedDB persistence, and upload behavior remain unchanged.

## Error handling

- Overlay resize failures or zero-size observations must not stop inference.
- Suspending or resuming an already stopped tracker is a no-op.
- Resume must not start overlapping inference calls.
- Existing camera initialization and detector failures continue through the current failure events.
- Trace samples that individually exceed the byte budget retain the existing diagnostic behavior.
- Browsers without Web Animations support use a non-layout-forcing fallback that still displays the cue.

## Testing

Implementation follows test-driven development. Focused tests will first fail for each required behavior:

1. repeated identical display models do not rewrite discrete DOM values;
2. frame and rep calculations are not duplicated within a tick;
3. work-fill progress is applied through one owned transform and remains visible;
4. DOWN cue restart does not require a layout read;
5. trace byte accounting preserves exact chunk boundaries without whole-buffer measurement on every sample;
6. hidden camera setup skips overlay rendering while inference continues;
7. pause suspends inference and trace capture, and resume resets temporal state without overlapping inference;
8. canvas resizing ignores zero dimensions and applies the first visible size.

Verification includes focused Node tests, the complete JavaScript test suite, proactive diagnostics, `mix precommit`, and the documented workout-session browser E2E where the available browser controller supports it. Physical iPhone 11 Safari profiling remains required to quantify improvements and decide whether later camera-quality trade-offs are justified.

## Success criteria

- Manual-mode workout frames avoid unchanged text, ARIA, class, hidden-state, and total-counter writes.
- Camera mode performs no overlay canvas work outside camera setup.
- Paused camera sessions perform no new pose inference or trace recording.
- Pose trace chunking remains byte-safe and payload-compatible.
- Workout timing, rep totals, cues, completion, persistence, and camera accuracy remain behaviorally unchanged.
- Existing automated suites and `mix precommit` pass.
- A physical iPhone 11 comparison shows reduced scripting/paint pressure; exact device metrics are recorded separately rather than treated as a prerequisite for source-level correctness.
