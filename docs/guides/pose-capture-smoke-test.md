# Pose Capture Smoke Test

## Summary

Use this checklist after changes to camera tracking, pose capture storage, MediaPipe assets, or session flow. The goal is to verify that tracked sessions can start, capture warmup and main pose chunks, save completed capture data, and delete pose data when the user aborts.

## Prerequisites

From the app repo:

```sh
cd ~/projects/vibe/burpee_trainer
mix assets.pose
mix phx.server
```

Open the app in a browser with WebGL enabled. If pose tracking fails in LibreWolf or another hardened browser, retry in Safari/Chrome/Firefox and check WebGL availability:

```js
document.createElement("canvas").getContext("webgl2")
document.createElement("canvas").getContext("webgl")
```

At least one of those should return a context object, not `null`.

## 1. MediaPipe asset check

Open the browser devtools Network tab and start the camera debug/tracked flow.

Confirm these requests return `200`, not `404`:

```text
/models/mediapipe_pose/pose_landmark_full.tflite
/models/mediapipe_pose/pose_solution_packed_assets_loader.js
/models/mediapipe_pose/pose_solution_packed_assets.data
/models/mediapipe_pose/pose_solution_simd_wasm_bin.js
/models/mediapipe_pose/pose_solution_simd_wasm_bin.wasm
/models/mediapipe_pose/pose_web.binarypb
```

If any are missing, run:

```sh
mix assets.pose
```

## 2. Camera debug smoke test

1. Go to `/tracking-test`.
2. Allow camera permission.
3. Confirm the status reaches `Live`.
4. Move in frame and confirm the skeleton/pose display updates.
5. Confirm there is no browser alert like:

```text
Failed to create WebGL canvas context when passing video frame
```

If that appears, try another browser or enable hardware acceleration/WebGL.

## 3. Completed tracked session smoke test

1. Go to a runnable workout plan.
2. Start a session.
3. Choose camera/tracked mode.
4. Confirm the camera setup step appears before warmup.
5. Confirm the setup panel changes to ready when the tracker loads.
6. Start the tracked session.
7. Complete at least part of warmup.
8. Continue into the main workout.
9. Finish and save the session.

Expected behavior:

- Camera setup appears before tracked work starts.
- The session records pose chunks during warmup and main.
- Saving creates a tracked `workout_session`.
- The `pose_capture_run` is marked completed and linked to that saved session.

## 4. Database checks after saving

In an IEx session or database browser, verify:

```elixir
alias BurpeeTrainer.Repo
alias BurpeeTrainer.Workouts.{PoseCaptureRun, PoseTraceChunk, WorkoutSession}
import Ecto.Query

session = Repo.one!(from s in WorkoutSession, order_by: [desc: s.id], limit: 1)
run = Repo.one!(from r in PoseCaptureRun, where: r.workout_session_id == ^session.id)
chunks = Repo.all(from c in PoseTraceChunk, where: c.pose_capture_run_id == ^run.id)

session.capture_mode
run.status
Enum.map(chunks, & &1.segment) |> Enum.uniq()
length(chunks)
```

Expected:

```elixir
session.capture_mode == :tracked
run.status == :completed
:warmup in Enum.map(chunks, & &1.segment)
:main in Enum.map(chunks, & &1.segment)
length(chunks) > 0
```

## 5. Abort/discard smoke test

1. Start another tracked session.
2. Allow the camera to start.
3. Let it run long enough to capture at least one chunk.
4. Abort/discard the session instead of saving.

Expected behavior:

- The app does not retain pose data from the aborted attempt.
- The related `pose_capture_run` and `pose_trace_chunks` are deleted.

Useful check before and after abort:

```elixir
Repo.aggregate(PoseCaptureRun, :count)
Repo.aggregate(PoseTraceChunk, :count)
```

The counts should not increase after an aborted tracked attempt.

## 6. Timer-only fallback smoke test

1. Start a session.
2. Choose timer-only mode.
3. Complete/save normally.

Expected behavior:

- No `#pose-tracker` is active.
- No new `pose_capture_run` is created.
- Saved session has `capture_mode == :timed`.

## 7. Theme/count-in visual check

Run one session in light mode and one in dark mode.

During count-in before a set starts, verify:

- The session background matches the selected theme.
- The header/count-in label does not invert to the opposite theme.
- The bottom nav/theme controls do not float over the session UI.

## 8. Final automated checks

After manual smoke testing, run:

```sh
mix precommit
cd assets && npm test
```

Expected current baselines after the P0 capture work:

```text
mix precommit: all tests pass
assets npm test: all tests pass
```
