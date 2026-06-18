# P0 pose capture design: camera setup and trace collection

## Goal

Add a tracked-session capture path that opens a live camera setup step before the workout starts, then records full raw-ish BlazePose body-pose traces for both warmup and main workout segments. Data collection must work even if live rep counting or HSMM decoding is not robust.

This is the first implementation priority. Export bundles, labelling, and model training all depend on this data existing.

## Non-goals

- Do not build the Bonsai labelling tool in this phase.
- Do not build the export/preprocessing bundle in this phase.
- Do not store video frames.
- Do not require HSMM or the current rep counter to be correct before saving data.
- Do not introduce TimescaleDB/Postgres.

## User flow

Current tracked session flow renders `PoseTracker` only after the user chooses tracked capture. Replace that blind start with an explicit setup flow:

```text
Session ready
→ user chooses camera tracking
→ camera setup opens
→ camera preview + skeleton + quality indicators
→ user adjusts phone/laptop angle
→ user taps "Start tracked session"
→ warmup segment records poses if warmup is used
→ main segment records poses
→ session completion links capture run to saved workout session
```

If the user skips warmup, capture still records the main segment. If the user aborts after setup or during warmup/main, keep the capture run with status `aborted` unless a later explicit cleanup feature deletes it.

## Camera setup screen

The setup screen should reuse the diagnostic capabilities from `/tracking-test`, but make them focused and non-debuggy.

Required elements:

- mirrored live video preview
- skeleton overlay
- camera/model status: requesting, loading model, live, failed
- FPS indicator
- pose confidence indicator
- full-body/framing indicator
- actionable hints when obvious, such as:
  - step back
  - body partly out of frame
  - camera too high/low
- start button enabled once camera and model are live

Setup is not a workout segment. V1 may discard setup samples. Warmup and main samples are required.

## Capture sample format

Each sample should preserve full raw-ish BlazePose landmarks plus derived feature values used by the current and future decoders.

Conceptual shape:

```json
{
  "t_ms": 12345,
  "segment": "warmup",
  "segment_t_ms": 2345,
  "model": "blazepose-full",
  "confidence": 0.86,
  "landmarks": [
    {
      "name": "nose",
      "x": 0.51,
      "y": 0.12,
      "z": -0.21,
      "visibility": 0.97,
      "presence": 0.99,
      "world_x": 0.01,
      "world_y": 0.42,
      "world_z": -0.31,
      "world_visibility": 0.97
    }
  ],
  "features": {
    "signal": 0.62,
    "closeness": 0.34,
    "visible_fraction": 0.88,
    "nose_y": 0.12,
    "shoulder_mid_y": 0.29,
    "hip_mid_y": 0.54,
    "d_signal": -0.08,
    "d_closeness": 0.04
  }
}
```

Implementation may normalize exact field names, but must keep:

- stable timestamps
- segment identity
- all 33 BlazePose landmarks when available
- normalized screen coordinates
- world coordinates when available
- visibility/presence/score metadata
- derived feature snapshot
- model/version metadata

## App storage

Use SQLite with compressed chunked blobs. Do not store pose traces directly on `workout_sessions`.

### `pose_capture_runs`

Represents one camera capture lifecycle.

Fields:

- `id`
- `user_id`
- `workout_session_id`, nullable until completion
- `plan_id`, nullable for future free-form captures
- `status`: `setup`, `recording`, `completed`, `aborted`, `failed`
- `model_name`, e.g. `blazepose-full`
- `model_version`
- `fps_target`, e.g. `15`
- `started_at`
- `ended_at`
- `duration_ms`
- `sample_count`
- `segments_json`, for warmup/main timing metadata
- `metadata_json`
- timestamps

### `pose_trace_chunks`

Stores compressed sample batches.

Fields:

- `id`
- `capture_run_id`
- `chunk_index`
- `segment`: `warmup` or `main`
- `start_ms`
- `end_ms`
- `sample_count`
- `codec`: initially choose an implementation-friendly compression format
- `payload`: blob
- timestamps

Chunk every 2–5 seconds. This avoids one giant payload at finish and keeps partial/aborted captures useful.

## Upload protocol

The browser creates a capture run before recording starts, then streams chunks while the session runs.

Suggested events/endpoints:

- `pose_capture_start`
- `pose_capture_chunk`
- `pose_capture_complete`
- `pose_capture_abort`
- `pose_capture_link_session`

If LiveView payload limits become awkward, switch chunk upload to regular HTTP endpoints while LiveView controls the workflow.

Chunk acceptance should be idempotent by `(capture_run_id, chunk_index)` so retries do not duplicate samples.

## Existing code to reuse

- `assets/js/hooks/blazepose_detector.mjs`
- `assets/js/hooks/pose_signal.mjs`
- `assets/js/hooks/pose_features.mjs`
- `assets/js/hooks/pose_tracker_impl.mjs`
- `assets/js/hooks/pose_debug.js` for preview/skeleton/debug ideas
- `lib/burpee_trainer_web/live/session_live.ex` tracked capture flow

## Error handling

- Camera permission denied: keep user in setup with an actionable message.
- Model load failure: show setup error; do not start tracked session.
- Chunk upload failure: retry; mark capture run failed only when retries are exhausted or the session ends without recovery.
- Session save failure: do not delete capture data; keep capture run unlinked or in a recoverable status.
- User abort: mark capture run `aborted` and keep chunks for training/debugging unless future cleanup deletes them.

## Tests

### Elixir

- capture run lifecycle creation/completion/abort
- chunk insertion idempotency
- chunk ordering and metadata validation
- tracked session links completed capture run
- session save failure does not delete capture run

### JS/browser boundary

- sample chunk builder includes warmup/main segment metadata
- chunking respects size/time bounds
- finish still saves cadence independent of pose chunk success
- setup state does not begin workout until camera/model are live

### Smoke tests

- tracked workout opens camera setup before warmup/main
- user can adjust camera and start
- warmup + main chunks are saved
- saved session links to capture run
- aborted capture remains inspectable
