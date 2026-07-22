const MIN_SCORE = 0.5;
const MIN_VISIBLE_FRACTION = 0.35;
const READY_STREAK = 8;
const LOST_STREAK = 3;

export function initialPoseReadiness() {
	return {
		status: "not_ready",
		passStreak: 0,
		failStreak: 0,
	};
}

export function stepPoseReadiness(state, { poseCount, sample }) {
	const coreReady = corePoseReady(poseCount, sample);
	const passStreak = coreReady ? state.passStreak + 1 : 0;
	const failStreak = coreReady ? 0 : state.failStreak + 1;

	if (state.status === "not_ready") {
		if (passStreak < READY_STREAK) {
			return { status: "not_ready", passStreak, failStreak };
		}
		return {
			status: optimalPose(sample) ? "optimal" : "ready",
			passStreak,
			failStreak: 0,
		};
	}

	if (failStreak >= LOST_STREAK) {
		return { status: "not_ready", passStreak: 0, failStreak };
	}

	return {
		status: coreReady && optimalPose(sample) ? "optimal" : state.status,
		passStreak,
		failStreak,
	};
}

function corePoseReady(poseCount, sample) {
	if (poseCount !== 1 || !sample) return false;
	if (sample.confidence < MIN_SCORE) return false;
	if ((sample.features?.visibleFraction || 0) < MIN_VISIBLE_FRACTION)
		return false;

	const points = sample.keypoints || {};
	const required = [
		points.left_shoulder,
		points.right_shoulder,
		points.left_hip,
		points.right_hip,
	];
	const kneeReady = visible(points.left_knee) || visible(points.right_knee);

	return required.every(visible) && kneeReady;
}

function optimalPose(sample) {
	const points = sample?.keypoints || {};
	const kneesReady = visible(points.left_knee) && visible(points.right_knee);
	const ankleReady = visible(points.left_ankle) || visible(points.right_ankle);
	return kneesReady && ankleReady && sample.features.visibleFraction >= 0.5;
}

function visible(point) {
	return (
		point != null &&
		point.score >= MIN_SCORE &&
		Number.isFinite(point.x) &&
		Number.isFinite(point.y) &&
		point.x >= 0 &&
		point.x <= 1 &&
		point.y >= 0 &&
		point.y <= 1
	);
}
