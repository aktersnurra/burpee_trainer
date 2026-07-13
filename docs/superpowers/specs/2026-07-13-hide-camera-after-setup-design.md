# Hide Camera Preview After Setup

**Date:** 2026-07-13  
**Status:** Approved

## Context

Tracked sessions render `#pose-tracker` with `phx-update="ignore"` so LiveView does not replace the active video, canvas, camera stream, or pose-estimation hook. The server already renders hidden classes when `capture_setup_state` becomes `:started`, but LiveView cannot patch those classes onto an ignored element. As a result, the camera preview remains visible after setup even though the workout flow proceeds.

## Goal

Hide the full camera preview surface immediately after the user taps **Start camera**, while leaving the camera stream and pose-estimation pipeline active for rep tracking.

## Non-goals

- Do not stop, pause, or reacquire the camera stream.
- Do not change camera selection, zoom behavior, or the 15 FPS pose-estimation rate.
- Do not hide the preview before camera setup is accepted.
- Do not redesign the camera setup or workout screens.

## Design

`SessionHook.onCameraSetupStart()` will take immediate ownership of this client-only visibility transition.

Before sending the existing `camera_setup_started` event or advancing the flow, it will find `#pose-tracker` beneath the session root and:

1. Remove the visible-state classes `z-10` and `opacity-100`.
2. Add the hidden-state classes `invisible`, `-z-10`, and `opacity-0`.
3. Leave the element, its `PoseTracker` hook, video, canvas, media stream, animation loop, and pose estimator mounted.

The class change must be idempotent. If `#pose-tracker` is absent, hiding is a no-op and the existing server event and workout flow still run.

The existing server-side `capture_setup_state == :started` classes remain as declarative fallback state for fresh renders. The active transition does not rely on LiveView patching an element marked `phx-update="ignore"`.

## Data Flow

1. The user frames themselves while the camera setup preview is visible.
2. The user taps `#camera-setup-start-btn`.
3. `SessionHook.onCameraSetupStart()` hides `#pose-tracker` locally.
4. The hook pushes `camera_setup_started` to LiveView.
5. The hook dispatches `CAMERA_SETUP_READY` and continues to the normal warmup prompt.
6. `PoseTracker` continues sampling the same stream and emitting tracking/rep events while its preview is invisible.

## Failure Behavior

- Missing tracker DOM: continue the workout flow without throwing.
- Repeated visibility-class application: remain hidden; existing server-event and flow behavior are unchanged.
- Server event latency or LiveView patch suppression: preview still hides immediately because the transition is local.
- Tracking or camera errors remain governed by the existing pose-tracker fallback behavior.

## Testing

Add JavaScript regression coverage that verifies:

- The visible tracker classes are replaced with the hidden tracker classes when camera setup starts.
- The existing `camera_setup_started` push and `CAMERA_SETUP_READY` flow still occur.
- A missing tracker element does not throw or block the flow.
- The hide path does not remove the tracker, stop media tracks, or request another stream.

Retain the existing camera acquisition, zoom-fallback, session-flow, and 15 FPS tests. Run the focused JavaScript test, full `npm test`, and `mix precommit` before deployment.

## Acceptance Criteria

- The preview is visible during camera arming and setup.
- Tapping **Start camera** immediately hides both the video and pose overlay.
- The warmup/workout session display replaces the preview visually.
- Pose tracking and rep counting continue from the same camera stream.
- No additional `getUserMedia()` call occurs.
- `POSE_FPS` remains `15`.
