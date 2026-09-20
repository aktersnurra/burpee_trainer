import { keypointsFromPoseLandmarks } from "./blazepose_detector.mjs";

const POSE_WASM_PATH = "/models/mediapipe_pose/wasm";
const POSE_MODEL_PATH = "/models/mediapipe_pose/pose_landmarker_full.task";

const POSE_WORKER_PATH = "/assets/js/pose_worker.js";

// BlazePose works from a 256x256 crop, so copying a full camera frame each
// tick is wasted main-thread work. Landmarks come back normalised and are
// scaled against the video element, so the smaller bitmap does not move them.
const MAX_FRAME_WIDTH = 640;

function frameSize(video) {
	const width = video?.videoWidth || video?.width || 0;
	const height = video?.videoHeight || video?.height || 0;
	if (width <= 0 || height <= 0 || width <= MAX_FRAME_WIDTH) {
		return { resizeWidth: width, resizeHeight: height, resizeQuality: "low" };
	}

	return {
		resizeWidth: MAX_FRAME_WIDTH,
		resizeHeight: Math.round((height / width) * MAX_FRAME_WIDTH),
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
