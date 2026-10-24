import { canDrainPoseTraces, createPoseTraceUploader } from "./pose_trace_uploader.mjs";

const FIRST_RETRY_MS = 5_000;
const MAX_RETRY_MS = 30_000;

export function startPoseTraceSync({
	documentRoot,
	windowRoot,
	openStore,
	fetch,
	csrfToken,
	setTimeout: schedule = globalThis.setTimeout,
	clearTimeout: cancel = globalThis.clearTimeout,
}) {
	let store = null;
	let uploader = null;
	let inFlight = null;
	let retryTimer = null;
	let retryDelay = FIRST_RETRY_MS;
	let stopped = false;

	function render(state, message = "") {
		if (stopped) return;
		const status = documentRoot.querySelector("#pose-upload-status");
		if (!status) return;
		status.hidden = state === "idle" || !canDrainPoseTraces(documentRoot);
		status.dataset.state = state;
		const text = documentRoot.querySelector("#pose-upload-message");
		if (text) text.textContent = message;
		const button = documentRoot.querySelector("#pose-upload-retry");
		if (button) button.hidden = state !== "pending";
	}

	function scheduleRetry() {
		if (stopped || retryTimer !== null) return;
		retryTimer = schedule(() => {
			retryTimer = null;
			return retry();
		}, retryDelay);
		retryDelay = Math.min(retryDelay * 2, MAX_RETRY_MS);
	}

	async function drain() {
		if (!store) {
			store = await openStore();
			uploader = createPoseTraceUploader({ store, fetch, csrfToken });
		}
		const ready = await store.listReadyTraceUploads();
		if (stopped) return;
		if (ready.length === 0) {
			retryDelay = FIRST_RETRY_MS;
			render("idle");
			return;
		}
		render("uploading", "Uploading poses… Keep this page open until it finishes.");
		const result = await uploader.drain();
		if (stopped) return;
		if (result.status === "complete") {
			retryDelay = FIRST_RETRY_MS;
			render("idle");
		} else {
			render("pending", pendingMessage(result));
			if (result.reason === "storage" || result.uploads.some((upload) => upload.reason === "storage")) {
				store = null;
				uploader = null;
			}
			scheduleRetry();
		}
	}

	function retry() {
		if (stopped) return Promise.resolve();
		if (inFlight) return inFlight;
		if (retryTimer !== null) cancel(retryTimer);
		retryTimer = null;
		// Do not start draining uploads while the camera runner owns the page.
		// Navigation resumes the durable queue as soon as the athlete returns Home.
		if (!documentRoot.querySelector("#pose-upload-status") ||
			!canDrainPoseTraces(documentRoot) || documentRoot.visibilityState === "hidden") {
			render("idle");
			return Promise.resolve();
		}
		inFlight = drain()
			.catch(() => {
				store = null;
				uploader = null;
				render("pending", "Cannot access pose storage. Uploads are not confirmed. Retrying automatically.");
				scheduleRetry();
			})
			.finally(() => { inFlight = null; });
		return inFlight;
	}

	const onRetry = () => { void retry(); };
	const onClick = (event) => {
		if (event.target.closest?.("#pose-upload-retry")) onRetry();
	};
	const events = ["online", "burpee:trace-upload-ready", "phx:page-loading-stop"];
	for (const name of events) windowRoot.addEventListener(name, onRetry);
	documentRoot.addEventListener("visibilitychange", onRetry);
	documentRoot.addEventListener("click", onClick);
	void retry();

	return {
		retry,
		stop() {
			stopped = true;
			if (retryTimer !== null) cancel(retryTimer);
			retryTimer = null;
			for (const name of events) windowRoot.removeEventListener(name, onRetry);
			documentRoot.removeEventListener("visibilitychange", onRetry);
			documentRoot.removeEventListener("click", onClick);
		},
	};
}

function pendingMessage(result) {
	if (result.reason === "storage") {
		return "Cannot access pose storage. Uploads are not confirmed. Retrying automatically.";
	}
	const failed = result.uploads.find((upload) => upload.status === "pending");
	if (failed.reason === "missing_chunks") {
		return `Pose upload for workout ${failed.sessionId} has no local frames. Its upload record is retained.`;
	}
	if (failed.reason === "http") {
		return `Pose upload failed (HTTP ${failed.httpStatus}). Poses remain on this device. Retrying automatically.`;
	}
	return "Poses are still on this device, not confirmed on the server yet. Retrying automatically.";
}
