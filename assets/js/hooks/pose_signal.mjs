import { featureFrameFromPose } from "./pose_features.mjs";

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

export function sampleFromPose(pose, tMs, video, prevFeature = null) {
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

	const features = featureFrameFromPose(pose, tMs, video, prevFeature);

	return {
		tMs: Math.max(0, Math.round(tMs)),
		model: pose?.model || null,
		signal: clamp01(verticalSignal - closeness * 0.45),
		closeness,
		confidence,
		keypoints: normalizedKeypoints(keypoints, width, height),
		features,
	};
}

function normalizedKeypoints(keypoints, width, height) {
	return Object.fromEntries(
		keypoints
			.filter((point) => point?.name || point?.part)
			.map((point) => [
				point.name || point.part,
				normalizedKeypoint(point, width, height),
			]),
	);
}

function normalizedKeypoint(point, width, height) {
	const normalized = {
		x: Number.isFinite(point.x) ? round4(point.x / width) : null,
		y: Number.isFinite(point.y) ? round4(point.y / height) : null,
		z: Number.isFinite(point.z) ? round4(point.z) : null,
		score: round4(point.score ?? 0),
	};

	if (point.visibility != null)
		normalized.visibility = round4(point.visibility);
	if (point.presence != null) normalized.presence = round4(point.presence);
	if (point.world) {
		normalized.world_x = round4(point.world.x);
		normalized.world_y = round4(point.world.y);
		normalized.world_z = round4(point.world.z);
		if (point.world.visibility != null) {
			normalized.world_visibility = round4(point.world.visibility);
		}
		if (point.world.presence != null) {
			normalized.world_presence = round4(point.world.presence);
		}
	}

	return normalized;
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

function round4(value) {
	return Math.round(value * 10000) / 10000;
}
