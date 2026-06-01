const BODY_KEYPOINTS = Object.freeze([
	"nose",
	"left_eye",
	"right_eye",
	"left_ear",
	"right_ear",
	"left_shoulder",
	"right_shoulder",
	"left_hip",
	"right_hip",
	"left_knee",
	"right_knee",
	"left_ankle",
	"right_ankle",
]);

export function sampleFromPose(pose, tMs, video) {
	const keypoints = pose?.keypoints || [];
	const points = BODY_KEYPOINTS.map((name) =>
		findKeypoint(keypoints, name),
	).filter(Boolean);
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
		closeness,
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
