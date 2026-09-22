import { FilesetResolver, PoseLandmarker } from "@mediapipe/tasks-vision";

let landmarker = null;
let activeDelegate = null;

function createLandmarker(fileset, modelPath, delegate) {
	return PoseLandmarker.createFromOptions(fileset, {
		baseOptions: { modelAssetPath: modelPath, delegate },
		runningMode: "VIDEO",
		numPoses: 1,
		minPoseDetectionConfidence: 0.5,
		minPosePresenceConfidence: 0.5,
		minTrackingConfidence: 0.5,
		outputSegmentationMasks: false,
	});
}

// The GPU delegate needs a WebGL context, which inside a worker can only come
// from OffscreenCanvas -- a path that has been unreliable in WebKit even
// though the same delegate works fine on the main thread. Try GPU first so
// engines that support it keep GPU offload, and only drop to the CPU
// delegate, still inside this worker, when GPU initialization itself fails.
async function init({ wasmPath, modelPath, delegate }) {
	const fileset = await FilesetResolver.forVisionTasks(wasmPath);
	const requested = delegate || "GPU";

	try {
		landmarker = await createLandmarker(fileset, modelPath, requested);
		activeDelegate = requested;
	} catch (error) {
		if (requested !== "GPU") throw error;
		landmarker = await createLandmarker(fileset, modelPath, "CPU");
		activeDelegate = "CPU";
	}
}

// The worker only ever holds one frame: the tracker waits for each result
// before sending the next, so there is no queue to drain here.
function detect(bitmap, timestamp) {
	try {
		const result = landmarker.detectForVideo(bitmap, timestamp);
		// Landmarks are plain numbers, so structured clone is cheap; the
		// bitmap itself is closed rather than returned.
		return {
			landmarks: result?.landmarks?.[0] || [],
			worldLandmarks: result?.worldLandmarks?.[0] || [],
		};
	} finally {
		bitmap.close();
	}
}

self.onmessage = async (event) => {
	const { id, type, payload } = event.data || {};

	try {
		if (type === "init") {
			await init(payload);
			self.postMessage({ id, ok: true, result: { delegate: activeDelegate } });
			return;
		}

		if (type === "detect") {
			self.postMessage({ id, ok: true, result: detect(payload.bitmap, payload.timestamp) });
			return;
		}

		if (type === "close") {
			landmarker?.close();
			landmarker = null;
			self.postMessage({ id, ok: true });
			return;
		}

		self.postMessage({ id, ok: false, error: `unknown message ${type}` });
	} catch (error) {
		self.postMessage({ id, ok: false, error: error?.message || String(error) });
	}
};
