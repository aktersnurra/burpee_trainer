const HAVE_CURRENT_DATA = 2;

export function isVideoFrameReady(video) {
	return Boolean(
		video &&
			video.readyState >= HAVE_CURRENT_DATA &&
			video.videoWidth > 0 &&
			video.videoHeight > 0,
	);
}

export function webglAvailable(documentLike = globalThis.document) {
	if (!documentLike?.createElement) return false;

	try {
		const canvas = documentLike.createElement("canvas");
		return Boolean(
			canvas.getContext("webgl2") ||
				canvas.getContext("webgl") ||
				canvas.getContext("experimental-webgl"),
		);
	} catch (_error) {
		return false;
	}
}

export async function waitForVideoFrame(video, options = {}) {
	const timeoutMs = options.timeoutMs ?? 4000;
	const now = options.now ?? (() => performance.now());
	const requestFrame = options.requestFrame ?? requestAnimationFrame;

	if (isVideoFrameReady(video)) return video;

	const startedAt = now();

	return new Promise((resolve, reject) => {
		let settled = false;
		let timeout = null;

		const cleanup = () => {
			if (timeout) clearTimeout(timeout);
			video.removeEventListener?.("loadedmetadata", check);
			video.removeEventListener?.("loadeddata", check);
			video.removeEventListener?.("canplay", check);
		};

		const finish = (result, value) => {
			if (settled) return;
			settled = true;
			cleanup();
			result(value);
		};

		function check() {
			if (isVideoFrameReady(video)) {
				finish(resolve, video);
				return;
			}

			if (now() - startedAt >= timeoutMs) {
				finish(reject, new Error("camera video did not become ready"));
			}
		}

		video.addEventListener?.("loadedmetadata", check);
		video.addEventListener?.("loadeddata", check);
		video.addEventListener?.("canplay", check);

		const poll = () => {
			if (settled) return;
			check();
			if (!settled) requestFrame(poll);
		};

		timeout = setTimeout(check, timeoutMs);
		poll();
	});
}
