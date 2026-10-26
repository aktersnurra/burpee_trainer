import { canDrainPoseTraces, createPoseTraceUploader } from "./pose_trace_uploader.mjs";

const FIRST_RETRY_MS = 5_000;
const MAX_RETRY_MS = 30_000;
const DISMISSED_KEY = "burpee:dismissed-pose-uploads";

// A dismissed notice stays dismissed on this device; a blocked queue keeps its poses either way.
function loadDismissed(storage) {
	try {
		const ids = JSON.parse(storage?.getItem(DISMISSED_KEY) ?? "[]");
		return new Set(Array.isArray(ids) ? ids : []);
	} catch {
		return new Set();
	}
}

function saveDismissed(storage, ids) {
	try {
		storage?.setItem(DISMISSED_KEY, JSON.stringify([...ids]));
	} catch {
		// Without storage the dismissal lasts this visit only.
	}
}

export function startPoseTraceSync({
	documentRoot,
	windowRoot,
	openStore,
	fetch,
	csrfToken,
	storage = safeLocalStorage(),
	CompressionStream = globalThis.CompressionStream,
	setTimeout: schedule = globalThis.setTimeout,
	clearTimeout: cancel = globalThis.clearTimeout,
}) {
	let store = null;
	let uploader = null;
	let inFlight = null;
	let retryTimer = null;
	let retryDelay = FIRST_RETRY_MS;
	let stopped = false;
	let rescanRequested = false;
	let blockedSessionId = null;
	const dismissedBlockedUploads = loadDismissed(storage);

	function render(state, message = "") {
		if (stopped) return;
		const status = documentRoot.querySelector("#pose-upload-status");
		if (!status) return;
		status.hidden = state === "idle" || !canDrainPoseTraces(documentRoot);
		status.dataset.state = state;
		if (state !== "blocked") blockedSessionId = null;
		const text = documentRoot.querySelector("#pose-upload-message");
		if (text) text.textContent = message;
		const button = documentRoot.querySelector("#pose-upload-retry");
		if (button) button.hidden = state !== "pending";
		const dismiss = documentRoot.querySelector("#pose-upload-dismiss");
		if (dismiss) dismiss.hidden = state !== "blocked";
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
			uploader = createPoseTraceUploader({ store, fetch, csrfToken, CompressionStream });
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
		} else if (result.status === "blocked") {
			retryDelay = FIRST_RETRY_MS;
			const blocked = result.uploads.find((upload) => upload.status === "blocked" && !dismissedBlockedUploads.has(upload.sessionId));
			if (blocked) {
				blockedSessionId = blocked.sessionId;
				render("blocked", blockedMessage(blocked));
			} else {
				render("idle");
			}
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
		inFlight = (async () => {
			do {
				rescanRequested = false;
				if (retryTimer !== null) cancel(retryTimer);
				retryTimer = null;
				await drain();
			} while (rescanRequested && !stopped && canDrainPoseTraces(documentRoot) && documentRoot.visibilityState !== "hidden");
		})()
			.catch(() => {
				store = null;
				uploader = null;
				render("pending", "Cannot access pose storage. Uploads are not confirmed. Retrying automatically.");
				scheduleRetry();
			})
			.finally(() => { inFlight = null; });
		return inFlight;
	}

	const onRetry = () => {
		if (inFlight) rescanRequested = true;
		else void retry();
	};
	const onClick = (event) => {
		if (event.target.closest?.("#pose-upload-retry")) onRetry();
		if (event.target.closest?.("#pose-upload-dismiss") && blockedSessionId !== null) {
			dismissedBlockedUploads.add(blockedSessionId);
			saveDismissed(storage, dismissedBlockedUploads);
			render("idle");
		}
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

function safeLocalStorage() {
	try {
		return globalThis.localStorage;
	} catch {
		return undefined;
	}
}

function pendingMessage(result) {
	if (result.reason === "storage") {
		return "Cannot access pose storage. Uploads are not confirmed. Retrying automatically.";
	}
	const failed = result.uploads.find((upload) => upload.status === "pending");
	if (failed.reason === "http") {
		return `Pose upload failed (HTTP ${failed.httpStatus}). Poses remain on this device. Retrying automatically.`;
	}
	return "Poses are still on this device, not confirmed on the server yet. Retrying automatically.";
}

function blockedMessage(upload) {
	if (upload.reason === "http") {
		const action = [401, 403].includes(upload.httpStatus)
			? "Sign in again, then reload to retry."
			: "Automatic retries stopped; dismiss this notice or reload after resolving the rejection.";
		return `Pose upload for workout ${upload.sessionId} was rejected (HTTP ${upload.httpStatus}). Poses remain on this device. ${action}`;
	}
	if (upload.reason === "oversized_chunk") {
		return `Pose upload for workout ${upload.sessionId} exceeds the request limit. Poses remain on this device; automatic retries stopped.`;
	}
	return `No local pose frames are available for workout ${upload.sessionId}. There is nothing to retry.`;
}
