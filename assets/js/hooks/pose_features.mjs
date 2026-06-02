const LANDMARK_NAMES = Object.freeze([
	"nose",
	"left_eye_inner",
	"left_eye",
	"left_eye_outer",
	"right_eye_inner",
	"right_eye",
	"right_eye_outer",
	"left_ear",
	"right_ear",
	"mouth_left",
	"mouth_right",
	"left_shoulder",
	"right_shoulder",
	"left_elbow",
	"right_elbow",
	"left_wrist",
	"right_wrist",
	"left_pinky",
	"right_pinky",
	"left_index",
	"right_index",
	"left_thumb",
	"right_thumb",
	"left_hip",
	"right_hip",
	"left_knee",
	"right_knee",
	"left_ankle",
	"right_ankle",
	"left_heel",
	"right_heel",
	"left_foot_index",
	"right_foot_index",
]);

const VISIBLE_SCORE = 0.5;

export function featureFrameFromPose(pose, tMs, video, prevFrame = null) {
	const width = video.videoWidth || video.width || 1;
	const height = video.videoHeight || video.height || 1;
	const points = new Map((pose?.keypoints || []).map((point) => [point.name || point.part, point]));
	const present = LANDMARK_NAMES.map((name) => points.get(name)).filter(Boolean);
	const visible = present.filter((point) => score(point) >= VISIBLE_SCORE);
	const poseConfidence = mean(present.map(score));
	const visibleFraction = present.length === 0 ? 0 : visible.length / LANDMARK_NAMES.length;
	const xs = visible.map((point) => point.x).filter(Number.isFinite);
	const ys = visible.map((point) => point.y).filter(Number.isFinite);
	const bboxWidthPx = xs.length ? Math.max(...xs) - Math.min(...xs) : null;
	const bboxHeightPx = ys.length ? Math.max(...ys) - Math.min(...ys) : null;
	const shoulderWidthPx = distance(points.get("left_shoulder"), points.get("right_shoulder"));
	const hipWidthPx = distance(points.get("left_hip"), points.get("right_hip"));
	const shoulderMid = midpoint(points.get("left_shoulder"), points.get("right_shoulder"));
	const hipMid = midpoint(points.get("left_hip"), points.get("right_hip"));
	const torsoLengthPx = distance(shoulderMid, hipMid);
	const scale = Math.max(torsoLengthPx || 0, shoulderWidthPx || 0, hipWidthPx || 0, 1);

	const frame = {
		tMs: Math.max(0, Math.round(tMs)),
		model: pose?.model || null,
		poseConfidence: round4(poseConfidence),
		confidence: round4(poseConfidence),
		visibleFraction: round4(visibleFraction),
		isOccluded: visibleFraction < 0.35,
		bboxWidth: norm(bboxWidthPx, width),
		bboxHeight: norm(bboxHeightPx, height),
		bboxArea: bboxWidthPx == null || bboxHeightPx == null ? null : round4((bboxWidthPx / width) * (bboxHeightPx / height)),
		bodyScale: norm(Math.max(bboxWidthPx || 0, bboxHeightPx || 0), Math.max(width, height)),
		noseY: yOf(points.get("nose"), height),
		shoulderMidX: xOf(shoulderMid, width),
		shoulderMidY: yOf(shoulderMid, height),
		hipMidX: xOf(hipMid, width),
		hipMidY: yOf(hipMid, height),
		kneeMidX: xOf(midpoint(points.get("left_knee"), points.get("right_knee")), width),
		kneeMidY: yOf(midpoint(points.get("left_knee"), points.get("right_knee")), height),
		ankleMidX: xOf(midpoint(points.get("left_ankle"), points.get("right_ankle")), width),
		ankleMidY: yOf(midpoint(points.get("left_ankle"), points.get("right_ankle")), height),
		wristMidX: xOf(midpoint(points.get("left_wrist"), points.get("right_wrist")), width),
		wristMidY: yOf(midpoint(points.get("left_wrist"), points.get("right_wrist")), height),
		footMidX: xOf(midpoint(points.get("left_foot_index"), points.get("right_foot_index")), width),
		footMidY: yOf(midpoint(points.get("left_foot_index"), points.get("right_foot_index")), height),
		shoulderWidth: norm(shoulderWidthPx, width),
		hipWidth: norm(hipWidthPx, width),
		torsoLength: norm(torsoLengthPx, height),
		upperBodyScore: round4(mean(namesScore(points, ["nose", "left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "left_wrist", "right_wrist"]))),
		hipScore: round4(mean(namesScore(points, ["left_hip", "right_hip"]))),
		kneeScore: round4(mean(namesScore(points, ["left_knee", "right_knee"]))),
		ankleScore: round4(mean(namesScore(points, ["left_ankle", "right_ankle"]))),
		normalizedLandmarks: normalizedLandmarks(points, hipMid, scale),
	};

	return addVelocities(frame, prevFrame);
}

export function featureFramesFromSamples(samples, video) {
	const frames = [];
	for (const sample of samples) {
		frames.push(featureFrameFromPose(sample.pose, sample.tMs, video, frames.at(-1) || null));
	}
	return frames;
}

function addVelocities(frame, prevFrame) {
	if (!prevFrame) {
		return {
			...frame,
			dNoseY: null,
			dShoulderY: null,
			dHipY: null,
			dWristY: null,
			dFootY: null,
			dBboxArea: null,
			dBodyScale: null,
		};
	}
	const dtSeconds = (frame.tMs - prevFrame.tMs) / 1000;
	return {
		...frame,
		dNoseY: velocity(frame.noseY, prevFrame.noseY, dtSeconds),
		dShoulderY: velocity(frame.shoulderMidY, prevFrame.shoulderMidY, dtSeconds),
		dHipY: velocity(frame.hipMidY, prevFrame.hipMidY, dtSeconds),
		dWristY: velocity(frame.wristMidY, prevFrame.wristMidY, dtSeconds),
		dFootY: velocity(frame.footMidY, prevFrame.footMidY, dtSeconds),
		dBboxArea: velocity(frame.bboxArea, prevFrame.bboxArea, dtSeconds),
		dBodyScale: velocity(frame.bodyScale, prevFrame.bodyScale, dtSeconds),
	};
}

function normalizedLandmarks(points, root, scale) {
	return Object.fromEntries(
		LANDMARK_NAMES.map((name) => {
			const point = points.get(name);
			const landmark = {
				x: point && root ? round4((point.x - root.x) / scale) : null,
				y: point && root ? round4((point.y - root.y) / scale) : null,
				z: Number.isFinite(point?.z) ? round4(point.z) : null,
				weight: round4(score(point)),
			};
			if (point?.world) {
				landmark.world_x = round4(point.world.x);
				landmark.world_y = round4(point.world.y);
				landmark.world_z = round4(point.world.z);
			}
			return [name, landmark];
		}),
	);
}

function midpoint(a, b) {
	if (!a || !b || !Number.isFinite(a.x) || !Number.isFinite(a.y) || !Number.isFinite(b.x) || !Number.isFinite(b.y)) return null;
	return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
}

function distance(a, b) {
	if (!a || !b || !Number.isFinite(a.x) || !Number.isFinite(a.y) || !Number.isFinite(b.x) || !Number.isFinite(b.y)) return null;
	return Math.hypot(a.x - b.x, a.y - b.y);
}

function namesScore(points, names) {
	return names.map((name) => score(points.get(name)));
}

function score(point) {
	return point?.score ?? point?.visibility ?? point?.presence ?? 0;
}

function mean(values) {
	const finite = values.filter(Number.isFinite);
	return finite.length === 0 ? 0 : finite.reduce((sum, value) => sum + value, 0) / finite.length;
}

function xOf(point, width) {
	return point ? norm(point.x, width) : null;
}

function yOf(point, height) {
	return point ? norm(point.y, height) : null;
}

function norm(value, divisor) {
	return Number.isFinite(value) ? round4(value / divisor) : null;
}

function velocity(value, prevValue, dtSeconds) {
	if (!Number.isFinite(value) || !Number.isFinite(prevValue) || dtSeconds <= 0) return null;
	return round4((value - prevValue) / dtSeconds);
}

function round4(value) {
	const rounded = Math.round(value * 10000) / 10000;
	return Object.is(rounded, -0) ? 0 : rounded;
}
