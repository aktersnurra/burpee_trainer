const KEYPOINTS = Object.freeze({
	leftShoulder: "left_shoulder",
	rightShoulder: "right_shoulder",
	leftHip: "left_hip",
	rightHip: "right_hip",
});

export function sampleFromPose(pose, tMs, video) {
	const keypoints = pose?.keypoints || [];
	const leftShoulder = findKeypoint(keypoints, KEYPOINTS.leftShoulder);
	const rightShoulder = findKeypoint(keypoints, KEYPOINTS.rightShoulder);
	const leftHip = findKeypoint(keypoints, KEYPOINTS.leftHip);
	const rightHip = findKeypoint(keypoints, KEYPOINTS.rightHip);

	const points = [leftShoulder, rightShoulder, leftHip, rightHip].filter(
		Boolean,
	);
	const confidence =
		points.length === 0
			? 0
			: points.reduce((sum, point) => sum + (point.score || 0), 0) /
				points.length;
	const yValues = points.map((point) => point.y).filter(Number.isFinite);
	const meanY =
		yValues.length === 0
			? video.videoHeight / 2
			: yValues.reduce((sum, y) => sum + y, 0) / yValues.length;
	const height = video.videoHeight || 1;
	const width = video.videoWidth || 1;
	const verticalSignal = 1 - meanY / height;
	const closeness = bodyCloseness(points, width, height);

	return {
		tMs: Math.max(0, Math.round(tMs)),
		signal: clamp01(verticalSignal - closeness * 0.45),
		confidence,
	};
}

function bodyCloseness(points, width, height) {
	const xs = points.map((point) => point.x).filter(Number.isFinite);
	const ys = points.map((point) => point.y).filter(Number.isFinite);

	if (xs.length < 2 || ys.length < 2) return 0;

	const boxWidth = Math.max(...xs) - Math.min(...xs);
	const boxHeight = Math.max(...ys) - Math.min(...ys);
	const widthRatio = boxWidth / width;
	const heightRatio = boxHeight / height;

	return clamp01(Math.max(widthRatio, heightRatio));
}

function findKeypoint(keypoints, name) {
	return keypoints.find((point) => point.name === name || point.part === name);
}

function clamp01(value) {
	if (value < 0) return 0;
	if (value > 1) return 1;
	return value;
}
