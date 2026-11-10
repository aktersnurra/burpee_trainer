export const POSE_FPS = 15;
export const POSE_INTERVAL_MS = 1000 / POSE_FPS;
// Animation frames land a millisecond or so either side of the interval. Without slack the
// fourth frame at 60 Hz misses half the time and the camera runs at 13 frames a second.
const SLACK_MS = 4;

export function shouldSamplePose(nowMs, lastPoseMs) {
	return nowMs - lastPoseMs >= POSE_INTERVAL_MS - SLACK_MS;
}
