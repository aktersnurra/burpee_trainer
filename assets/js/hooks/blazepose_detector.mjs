import { FilesetResolver, PoseLandmarker } from "@mediapipe/tasks-vision";

const POSE_WASM_PATH = "/models/mediapipe_pose/wasm";
const POSE_MODEL_PATH = "/models/mediapipe_pose/pose_landmarker_full.task";

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

async function createDefaultPoseLandmarker() {
	const fileset = await FilesetResolver.forVisionTasks(POSE_WASM_PATH);

	return PoseLandmarker.createFromOptions(fileset, {
		baseOptions: { modelAssetPath: POSE_MODEL_PATH, delegate: "GPU" },
		runningMode: "VIDEO",
		numPoses: 1,
		minPoseDetectionConfidence: 0.5,
		minPosePresenceConfidence: 0.5,
		minTrackingConfidence: 0.5,
		outputSegmentationMasks: false,
	});
}

export async function createBlazePoseDetector(runtime = {}) {
	const createLandmarker =
		runtime.createPoseLandmarker || createDefaultPoseLandmarker;
	const now = runtime.now || (() => performance.now());
	const landmarker = await createLandmarker();
	// detectForVideo rejects a timestamp that does not advance, so keep our own
	// strictly increasing clock rather than trusting the caller's.
	let lastTimestamp = -1;

	return {
		async estimatePoses(video) {
			const timestamp = Math.max(now(), lastTimestamp + 1);
			lastTimestamp = timestamp;
			const result = landmarker.detectForVideo(video, timestamp);
			const pose = poseFromPoseLandmarkerResult(result, video);
			return pose ? [pose] : [];
		},
		dispose() {
			landmarker.close();
		},
	};
}

export function poseFromPoseLandmarkerResult(result, video) {
	const landmarks = result?.landmarks?.[0];
	if (!landmarks?.length) return null;

	return {
		model: "blazepose-full",
		keypoints: keypointsFromPoseLandmarks(
			landmarks,
			video,
			result.worldLandmarks?.[0] || [],
		),
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

export function keypointsFromPoseLandmarks(
	landmarks,
	video,
	worldLandmarks = [],
) {
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
