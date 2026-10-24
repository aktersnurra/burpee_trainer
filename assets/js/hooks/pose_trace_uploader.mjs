import { serializedJsonBytes } from "./pose_capture_recorder.mjs";

const DEFAULT_BATCH_SIZE = 20;
const DEFAULT_ENDPOINT = "/api/session-pose-traces";
export const MAX_TRACE_REQUEST_BYTES = 512 * 1024;

export function canDrainPoseTraces(documentRoot) {
	return !documentRoot.querySelector("#burpee-session");
}

export function createPoseTraceUploader({
	store,
	fetch,
	csrfToken,
	batchSize = DEFAULT_BATCH_SIZE,
	endpoint = DEFAULT_ENDPOINT,
	requestTimeoutMs = 30_000,
}) {
	let inFlight = null;

	async function postBatch(body) {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), requestTimeoutMs);
		try {
			const response = await fetch(endpoint, {
				method: "POST",
				headers: {
					"content-type": "application/json",
					"x-csrf-token": typeof csrfToken === "function" ? csrfToken() : csrfToken,
				},
				body: JSON.stringify(body),
				signal: controller.signal,
			});
			if (!response.ok) return { reason: "http", httpStatus: response.status };
			try {
				return { body: await response.json() };
			} catch {
				return { reason: controller.signal.aborted ? "timeout" : "invalid_response" };
			}
		} catch {
			return { reason: controller.signal.aborted ? "timeout" : "network" };
		} finally {
			clearTimeout(timeout);
		}
	}

	async function drainUpload(upload) {
		while (true) {
			const batch = [];
			const { hasMore } = await store.readTraceChunkBatch(upload.session_id, (chunk) => {
				if (batch.length === batchSize) return false;
				const candidate = [...batch, stripStoreFields(chunk)];
				// false is one byte larger than true, so this also bounds the final request.
				if (serializedJsonBytes(traceRequest(upload, candidate, false)) > MAX_TRACE_REQUEST_BYTES) return false;
				batch.push(candidate.at(-1));
				return true;
			});
			if (batch.length === 0) return pendingUpload(upload, hasMore ? "oversized_chunk" : "missing_chunks");

			const finalBatch = !hasMore;
			const posted = await postBatch(traceRequest(upload, batch, finalBatch));
			if (posted.reason) return pendingUpload(upload, posted.reason, posted.httpStatus);

			const result = posted.body;
			const batchIndexes = new Set(batch.map((chunk) => chunk.chunk_index));
			const acceptedIndexes = Array.isArray(result?.accepted_indexes)
				? [...new Set(result.accepted_indexes.filter((index) => batchIndexes.has(index)))]
				: [];
			if (acceptedIndexes.length === 0) return pendingUpload(upload, "invalid_acknowledgement");

			if (finalBatch && acceptedIndexes.length === batch.length && result.complete !== true) {
				return pendingUpload(upload, "incomplete_acknowledgement");
			}
			if (acceptedIndexes.length !== batch.length) {
				await store.deleteTraceChunks(upload.session_id, acceptedIndexes);
				return pendingUpload(upload, "partial_acknowledgement");
			}
			if (finalBatch) {
				await store.settleAcknowledgedFinalUpload(upload.session_id, acceptedIndexes);
				return { sessionId: upload.session_id, status: "uploaded" };
			}
			await store.deleteTraceChunks(upload.session_id, acceptedIndexes);
		}
	}

	async function drainReadyUploads() {
		const ready = await store.listReadyTraceUploads();
		const uploads = [];
		for (const upload of ready) {
			try {
				uploads.push(await drainUpload(upload));
			} catch {
				uploads.push(pendingUpload(upload, "storage"));
			}
		}
		return {
			status: uploads.every((upload) => upload.status === "uploaded") ? "complete" : "pending",
			uploads,
		};
	}

	return {
		drain() {
			if (inFlight) return inFlight;
			inFlight = drainReadyUploads()
				.catch(() => ({ status: "pending", reason: "storage", uploads: [] }))
				.finally(() => { inFlight = null; });
			return inFlight;
		},
	};
}

function pendingUpload(upload, reason, httpStatus) {
	const pending = { sessionId: upload.session_id, status: "pending", reason };
	if (httpStatus !== undefined) pending.httpStatus = httpStatus;
	return pending;
}

function traceRequest(upload, chunks, complete) {
	return {
		session_id: upload.session_id,
		client_session_id: upload.client_session_id,
		chunks,
		complete,
	};
}

function stripStoreFields(chunk) {
	const {
		session_id: _sessionId,
		client_session_id: _clientSessionId,
		...requestChunk
	} = chunk;
	return requestChunk;
}
