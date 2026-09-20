import { keypointsFromPoseLandmarks } from "./blazepose_detector.mjs";

const POSE_WASM_PATH = "/models/mediapipe_pose/wasm";
const POSE_MODEL_PATH = "/models/mediapipe_pose/pose_landmarker_full.task";

const POSE_WORKER_PATH = "/assets/js/pose_worker.js";

// The bundled models take fixed square inputs -- pose_detector.tflite is
// 224x224 and pose_landmarks_detector.tflite is 256x256 -- and MediaPipe fits
// the frame's short side to that square. Detail below the larger of the two is
// discarded before inference, so transferring more is wasted copy work.
//
// The cap is on the SHORT side, not the width: a portrait camera frame capped
// by width stays nearly full size on its long side.
const MODEL_INPUT_PX = 256;

function frameSize(video) {
	const width = video?.videoWidth || video?.width || 0;
	const height = video?.videoHeight || video?.height || 0;
	const shortSide = Math.min(width, height);
	if (shortSide <= 0 || shortSide <= MODEL_INPUT_PX) {
		return { resizeWidth: width, resizeHeight: height, resizeQuality: "low" };
	}

	const scale = MODEL_INPUT_PX / shortSide;
	return {
		resizeWidth: Math.round(width * scale),
		resizeHeight: Math.round(height * scale),
		resizeQuality: "low",
	};
}

function createDefaultWorker() {
	return new Worker(POSE_WORKER_PATH, { type: "module" });
}

// Runs BlazePose in a dedicated worker so inference never blocks the animation
// frame that drives the workout fill. Each frame is copied into an ImageBitmap
// and transferred, because a video element cannot cross the worker boundary.
export async function createWorkerPoseDetector(runtime = {}) {
	const spawn = runtime.createWorker || createDefaultWorker;
	const grabFrame = runtime.createImageBitmap || globalThis.createImageBitmap;
	const now = runtime.now || (() => performance.now());
	const delegate = runtime.delegate || "GPU";

	const worker = spawn();
	const pending = new Map();
	let nextId = 0;
	let lastTimestamp = -1;

	worker.onmessage = (event) => {
		const { id, ok, result, error } = event.data || {};
		const settle = pending.get(id);
		if (!settle) return;
		pending.delete(id);
		if (ok) settle.resolve(result);
		else settle.reject(new Error(error || "pose worker failed"));
	};

	// A worker that dies must reject everything waiting on it. Leaving those
	// promises pending would hang the sampling loop, and the tracker would stop
	// reporting without ever raising a detector error.
	const rejectPending = (reason) => {
		const waiting = [...pending.values()];
		pending.clear();
		for (const settle of waiting) settle.reject(reason);
	};

	worker.onerror = (event) => {
		rejectPending(new Error(event?.message || "pose worker crashed"));
	};

	const send = (type, payload, transfer) =>
		new Promise((resolve, reject) => {
			const id = ++nextId;
			pending.set(id, { resolve, reject });
			worker.postMessage({ id, type, payload }, transfer);
		});

	try {
		await send("init", {
			wasmPath: runtime.wasmPath || POSE_WASM_PATH,
			modelPath: runtime.modelPath || POSE_MODEL_PATH,
			delegate,
		});
	} catch (error) {
		worker.terminate();
		throw error;
	}

	return {
		async estimatePoses(video) {
			// The video running mode rejects a timestamp that does not advance.
			const timestamp = Math.max(now(), lastTimestamp + 1);
			lastTimestamp = timestamp;

			const bitmap = await grabFrame(video, frameSize(video));
			const result = await send("detect", { bitmap, timestamp }, [bitmap]);
			const landmarks = result?.landmarks;
			if (!landmarks?.length) return [];

			return [
				{
					model: "blazepose-full",
					keypoints: keypointsFromPoseLandmarks(
						landmarks,
						video,
						result.worldLandmarks || [],
					),
				},
			];
		},
		dispose() {
			worker.terminate();
			rejectPending(new Error("pose worker disposed"));
		},
	};
}
