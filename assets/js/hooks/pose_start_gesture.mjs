const MIN_SCORE = 0.5;

export function initialStartGesture() {
	return { streak: 0, satisfied: false };
}

export function stepStartGesture(state, { sample, holdFramesRequired }) {
	const raised = wristRaised(sample);
	const streak = raised ? state.streak + 1 : 0;

	return {
		streak,
		satisfied: streak >= holdFramesRequired,
	};
}

function wristRaised(sample) {
	const points = sample?.keypoints || {};
	return (
		raisedPair(points.left_wrist, points.left_shoulder) ||
		raisedPair(points.right_wrist, points.right_shoulder)
	);
}

function raisedPair(wrist, shoulder) {
	return visible(wrist) && visible(shoulder) && wrist.y < shoulder.y;
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
