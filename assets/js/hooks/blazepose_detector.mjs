import mediapipePose from "@mediapipe/pose";

const { Pose } = mediapipePose;

const BLAZEPOSE_MODEL_PATH = "/models/mediapipe_pose";

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

export async function createBlazePoseDetector() {
	let latestLandmarks = null;
	const pose = new Pose({
		locateFile: (file) => `${BLAZEPOSE_MODEL_PATH}/${file}`,
	});

	pose.setOptions({
		modelComplexity: 1,
		smoothLandmarks: true,
		enableSegmentation: false,
		smoothSegmentation: false,
		minDetectionConfidence: 0.5,
		minTrackingConfidence: 0.5,
	});
	pose.onResults((results) => {
		latestLandmarks = results || null;
	});
	await pose.initialize();

	return {
		async estimatePoses(video) {
			latestLandmarks = null;
			await pose.send({ image: video });
			if (!latestLandmarks?.poseLandmarks) return [];
			return [poseFromBlazePoseResults(latestLandmarks, video)];
		},
		dispose() {
			pose.close();
		},
	};
}

export function poseFromBlazePoseResults(results, video) {
	return {
		model: "blazepose-full",
		keypoints: keypointsFromPoseLandmarks(
			results.poseLandmarks || [],
			video,
			results.poseWorldLandmarks || [],
		),
	};
}

export function keypointsFromPoseLandmarks(landmarks, video, worldLandmarks = []) {
	const width = video.videoWidth || video.width || 1;
	const height = video.videoHeight || video.height || 1;

	return landmarks.map((landmark, index) => {
		const world = worldLandmarks[index];
		const point = {
			name: LANDMARK_NAMES[index] || `landmark_${index}`,
			x: round1(landmark.x * width),
			y: round1(landmark.y * height),
			z: round4(landmark.z ?? 0),
			score: landmark.visibility ?? landmark.presence ?? 0,
		};

		if (landmark.visibility != null) point.visibility = landmark.visibility;
		if (landmark.presence != null) point.presence = landmark.presence;
		if (world) {
			point.world = {
				x: world.x,
				y: world.y,
				z: world.z,
			};
			if (world.visibility != null) point.world.visibility = world.visibility;
			if (world.presence != null) point.world.presence = world.presence;
		}

		return point;
	});
}

function round1(value) {
	return Math.round(value * 10) / 10;
}

function round4(value) {
	const rounded = Math.round(value * 10000) / 10000;
	return Object.is(rounded, -0) ? 0 : rounded;
}
