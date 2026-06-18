# Pose capture and Bonsai labelling design

## Goal

Build a local-first pose data pipeline for burpee training sessions. The first priority is to collect high-quality full-body BlazePose traces from real workouts, including warmups, so the data can later train and evaluate rep/phase models. Live rep counting and HSMM robustness must not gate data capture.

The second priority is an OCaml/Bonsai labelling tool for replaying captured sessions, tagging intervals, correcting model predictions, and producing labels for Python training workflows.

## Non-goals

- Do not store video frames.
- Do not require the HSMM decoder to be accurate before saving traces.
- Do not replace Python-based model training with browser/WASM training.
- Do not build the labelling UI in TypeScript/JavaScript. Small browser FFI shims are acceptable only at unavoidable web API boundaries.
- Do not introduce TimescaleDB/Postgres for v1.

## Priority order

1. **P0: Camera setup and pose trace collection**
   - A tracked session must open a live camera setup step before warmup or main workout starts.
   - The user can adjust phone/laptop angle using a live preview, skeleton overlay, FPS/confidence/framing indicators, and a clear start button.
   - Once started, the app records raw-ish full BlazePose samples for both warmup and main workout.

2. **P1: Persist traces as training data**
   - Store full raw-ish pose trajectories in SQLite as compressed chunks, separate from `workout_sessions`.
   - Preserve enough metadata to replay, decode, and train on traces later.

3. **P2: Bonsai labelling tool**
   - Build a local web labelling UI in OCaml/Bonsai for replay, scrub, tag, and label traces.
   - Save labels separately from raw traces and decoder outputs.

4. **P3: Offline/model analysis**
   - Export traces and labels for Python training.
   - Re-run HSMM/TCN analysis over old traces and store derived rep/phase results.

## Capture flow

### Tracked session start

Current tracked sessions render `PoseTracker` only after the user chooses tracked capture. The new flow adds an explicit setup state:

```text
Session ready
→ user chooses camera tracking
→ camera setup opens
→ camera preview + skeleton + quality indicators
→ user taps "Start tracked session"
→ warmup segment records poses
→ main segment records poses
→ session completion links capture run to saved workout session
```

If the user skips warmup, capture still records the main segment. If the user aborts after setup or during warmup/main, the capture run remains stored with status `aborted` unless deletion is explicitly requested later.

### Camera setup UI

The setup screen should reuse the diagnostic concepts from `/tracking-test`, but as a focused preflight surface:

- live mirrored video preview
- skeleton overlay
- camera status: requesting, loading model, live, failed
- FPS
- pose confidence
- full-body/framing indicator
- simple hints such as "step back", "body partly out of frame", "camera too high/low" when detectable
- start button enabled once camera and model are live

This screen is not a training session. Samples collected here can be discarded by default or stored as `segment = "setup"` only if later useful; v1 should prioritize warmup/main data.

## Pose sample format

Each sample is timestamped relative to the capture run and carries segment information:

```json
{
  "t_ms": 12345,
  "segment": "warmup",
  "segment_t_ms": 2345,
  "model": "blazepose-full",
  "confidence": 0.86,
  "fps_sampled": 15,
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

Exact field names should be normalized when implemented. The important rule is that raw landmarks and derived features remain available for later decoders and training.

## Storage design

Use SQLite with compressed chunked blobs. Do not store traces as one giant JSON field on `workout_sessions`.

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
- `segments_json`, e.g. warmup/main timing metadata
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
- `codec`: initially `json+gzip` or another built-in compression available from Elixir without adding operational services
- `payload`: blob
- timestamps

Chunk every 2–5 seconds. This avoids sending a huge WebSocket payload at finish and makes partial/aborted captures useful.

### `pose_analysis_runs`

Derived and rerunnable analysis for a capture.

Fields:

- `id`
- `capture_run_id`
- `decoder_name`, e.g. `hsmm`, `tcn-v1`
- `decoder_version`
- `status`: `completed`, `failed`
- `diagnostics_json`
- timestamps

### `pose_reps`

Derived rep segmentation from an analysis run.

Fields:

- `id`
- `analysis_run_id`
- `segment`
- `rep_index`
- `start_ms`
- `bottom_ms`
- `end_ms`
- `duration_ms`
- `variant`
- `confidence`
- `diagnostics_json`

### `pose_labels`

Manual or model-assisted labels used for training.

Fields:

- `id`
- `capture_run_id`
- `segment`
- `start_ms`
- `end_ms`
- `label_type`: `phase`, `rep`, `quality`, `tag`
- `label`: e.g. `descending`, `bottom`, `rep`, `bad_angle`, `occluded`, `fatigue`
- `source`: `manual`, `hsmm`, `tcn`, `imported`
- `metadata_json`
- timestamps

Raw traces are immutable. Labels and analysis runs are append/update workflows layered on top.

## Upload protocol

The browser should create a capture run before recording starts, then stream chunks while the session runs.

Suggested LiveView events or endpoints:

- `pose_capture_start`
- `pose_capture_chunk`
- `pose_capture_complete`
- `pose_capture_abort`
- `pose_capture_link_session`

If LiveView payload limits become awkward, switch chunk upload to regular HTTP endpoints while the LiveView session controls the workflow.

Chunk acceptance should be idempotent by `(capture_run_id, chunk_index)` so retries do not duplicate samples.

## Labelling tool

Build the labelling tool as a Bonsai web app, served from the Phoenix app.

Routes can start as:

```text
/studio/pose-captures
/studio/pose-captures/:id/label
```

The labelling app should support:

- capture list and metadata filters
- loading chunked traces
- skeleton replay
- timeline scrubber
- playback speed control
- interval selection
- label creation/edit/delete
- keyboard shortcuts for common labels
- overlay of HSMM/TCN predictions vs manual labels
- save labels to Phoenix

Implementation should keep application logic in OCaml/Bonsai. Small FFI modules may bridge browser APIs, canvas rendering, and fetch calls if necessary.

## Training workflow

Training should remain Python-based.

A future export task can emit trace/label datasets:

```text
mix pose.export_training_data --capture-run-id ...
python train_tcn.py data/pose_exports/...
```

Likely model inputs:

- landmark trajectories over a time window
- visibility/presence/confidence channels
- derived geometry features
- velocity features
- segment metadata

Likely labels:

- frame/window phase labels: `top_anchor`, `descending`, `bottom`, `rising`, `rest_standing`, `unknown`
- event labels: `rep_start`, `bottom`, `rep_end`
- interval tags: `bad_angle`, `occluded`, `partial_body`, `fatigue`, `bad_rep`, etc.

Do not block capture on having labels. Data collection comes first.

## WASM stance

Do not build the whole labelling tool in WASM. Bonsai/js_of_ocaml is the source-language choice for the UI.

A future WASM or js_of_ocaml analysis core is appropriate for pure compute boundaries:

```text
Trace -> DecodeOptions -> DecodeResult
```

Potential compute modules:

- HSMM/Viterbi
- DTW/template matching
- feature normalization
- candidate scoring

The UI should treat the decoder as a swappable backend so a JS, OCaml, or Rust/WASM implementation can be substituted later.

## Error handling

- Camera permission denied: keep user in setup with actionable message.
- Model load failure: show setup error; do not start tracked session.
- Chunk upload failure: retry; mark capture run failed only when retries are exhausted or the session ends without recovery.
- Session save failure: do not delete capture data; keep capture run unlinked or `completed_unlinked` equivalent for manual recovery.
- Decoder failure: store failed analysis diagnostics without modifying raw trace or labels.

## Testing plan

### Elixir tests

- capture run lifecycle creation/completion/abort
- chunk insertion idempotency
- chunk ordering and metadata validation
- tracked session links completed capture run
- session save failure does not delete capture run
- labels can be created, updated, deleted, and filtered by capture run

### JS/browser boundary tests

- sample chunk builder includes warmup/main segment metadata
- chunking respects size/time bounds
- finish still saves cadence independent of pose chunk success

### Bonsai tests

- capture list renders loaded metadata
- label editor creates interval labels
- keyboard shortcuts create expected labels
- prediction overlay and manual labels render distinctly
- unsaved-change state is preserved across timeline scrubbing

### Smoke tests

- `/tracking-test` still works for raw diagnostics
- tracked workout opens camera setup before warmup/main
- user can adjust camera and start
- warmup + main chunks are saved
- saved session links to capture run
- trace can be loaded in labelling tool

## Open implementation details

- Exact compression codec should be chosen during implementation based on available Elixir/browser support.
- Bonsai project layout and Phoenix asset integration need a small spike before full labelling UI work.
- Setup samples are not stored in v1 unless needed; warmup and main are required.
