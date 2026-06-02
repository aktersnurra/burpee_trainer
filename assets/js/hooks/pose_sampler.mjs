export const POSE_FPS = 15;
export const POSE_INTERVAL_MS = 1000 / POSE_FPS;

export function shouldSamplePose(nowMs, lastPoseMs) {
	return nowMs - lastPoseMs >= POSE_INTERVAL_MS;
}
