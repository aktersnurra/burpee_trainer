import { FilesetResolver, PoseLandmarker } from "@mediapipe/tasks-vision";

let landmarker = null;

async function init({ wasmPath, modelPath, delegate }) {
	const fileset = await FilesetResolver.forVisionTasks(wasmPath);

	landmarker = await PoseLandmarker.createFromOptions(fileset, {
		baseOptions: { modelAssetPath: modelPath, delegate },
		runningMode: "VIDEO",
		numPoses: 1,
		minPoseDetectionConfidence: 0.5,
		minPosePresenceConfidence: 0.5,
		minTrackingConfidence: 0.5,
		outputSegmentationMasks: false,
	});
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
			self.postMessage({ id, ok: true });
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
