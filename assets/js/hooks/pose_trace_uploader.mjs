import { serializedJsonBytes } from "./pose_capture_recorder.mjs";

// A 20-minute session is a few hundred chunks; a handful of requests should carry it.
const DEFAULT_BATCH_SIZE = 50;
const DEFAULT_ENDPOINT = "/api/session-pose-traces";
// Decoded JSON per request; the server's PoseUploadBodyReader accepts the same.
export const MAX_TRACE_REQUEST_BYTES = 4 * 1024 * 1024;

export function canDrainPoseTraces(documentRoot) {
	return !documentRoot.querySelector("#burpee-session");
}

export function createPoseTraceUploader({
	store,
	fetch,
	csrfToken,
	batchSize = DEFAULT_BATCH_SIZE,
	endpoint = DEFAULT_ENDPOINT,
	requestTimeoutMs = 60_000,
	CompressionStream: Compression = globalThis.CompressionStream,
	// Called with the number of chunks the server accepted, after each batch.
	onProgress = () => {},
}) {
	let inFlight = null;
	const blockedUploads = new Map();

	async function postBatch(body) {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), requestTimeoutMs);
		try {
			const headers = {
				"content-type": "application/json",
				"x-csrf-token": typeof csrfToken === "function" ? csrfToken() : csrfToken,
			};
			let encoded = JSON.stringify(body);
			if (Compression) {
				const compressed = await new Response(new Blob([encoded]).stream().pipeThrough(new Compression("gzip"))).arrayBuffer();
				// Incompressible small payloads can grow; keep both wire and decoded size bounded.
				if (compressed.byteLength < new TextEncoder().encode(encoded).byteLength) {
					encoded = compressed;
					headers["content-encoding"] = "gzip";
				}
			}
			const response = await fetch(endpoint, {
				method: "POST",
				headers,
				body: encoded,
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
			if (batch.length === 0) {
				if (hasMore) return pendingUpload(upload, "oversized_chunk");
				return { sessionId: upload.session_id, status: "blocked", reason: "missing_chunks" };
			}

			const finalBatch = !hasMore;
			const posted = await postBatch(traceRequest(upload, batch, finalBatch));
			if (posted.reason) return pendingUpload(upload, posted.reason, posted.httpStatus);

			const result = posted.body;
			const batchIndexes = new Set(batch.map((chunk) => chunk.chunk_index));
			const acceptedIndexes = Array.isArray(result?.accepted_indexes)
				? [...new Set(result.accepted_indexes.filter((index) => batchIndexes.has(index)))]
				: [];
			if (acceptedIndexes.length === 0) return pendingUpload(upload, "invalid_acknowledgement");
			onProgress(acceptedIndexes.length);

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
				const result = blockedUploads.get(upload.session_id) || await drainUpload(upload);
				// Missing chunks and sign-in errors can clear without a reload, so they are retried on the next drain.
				if (result.status === "blocked" && result.reason !== "missing_chunks" && ![401, 403].includes(result.httpStatus)) {
					blockedUploads.set(upload.session_id, result);
				}
				uploads.push(result);
			} catch (error) {
				uploads.push({ ...pendingUpload(upload, "storage"), error: describeError(error) });
			}
		}
		if (uploads.some((upload) => upload.status === "pending")) return { status: "pending", uploads };
		if (uploads.some((upload) => upload.status === "blocked")) return { status: "blocked", uploads };
		return { status: "complete", uploads };
	}

	return {
		drain() {
			if (inFlight) return inFlight;
			inFlight = drainReadyUploads()
				.catch((error) => ({ status: "pending", reason: "storage", error: describeError(error), uploads: [] }))
				.finally(() => { inFlight = null; });
			return inFlight;
		},
	};
}

// Shown in the upload notice, so a storage failure on a phone says what it was.
export function describeError(error) {
	return error instanceof Error ? `${error.name}: ${error.message}` : String(error);
}

function pendingUpload(upload, reason, httpStatus) {
	const permanent = reason === "oversized_chunk" ||
		(reason === "http" && httpStatus >= 400 && httpStatus < 500 && ![408, 429].includes(httpStatus));
	const pending = { sessionId: upload.session_id, status: permanent ? "blocked" : "pending", reason };
	if (httpStatus !== undefined) pending.httpStatus = httpStatus;
	return pending;
}

function traceRequest(upload, chunks, complete) {
	return {
		expected_chunk_count: upload.expected_chunk_count ?? (chunks.at(-1)?.chunk_index + 1),
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
