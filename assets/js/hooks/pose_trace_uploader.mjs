const DEFAULT_BATCH_SIZE = 20;
const DEFAULT_ENDPOINT = "/api/session-pose-traces";

export function canDrainPoseTraces(documentRoot) {
	return !documentRoot.querySelector("#burpee-session");
}

export function createPoseTraceUploader({
	store,
	fetch,
	csrfToken,
	batchSize = DEFAULT_BATCH_SIZE,
	endpoint = DEFAULT_ENDPOINT,
}) {
	let inFlight = null;

	async function drainUpload(upload) {
		while (true) {
			const chunks = await store.listTraceChunks(upload.client_session_id);

			if (chunks.length === 0) {
				await store.completeTraceUpload(upload.client_session_id);
				return;
			}

			const batch = chunks.slice(0, batchSize);
			const finalBatch = batch.length === chunks.length;
			const response = await fetch(endpoint, {
				method: "POST",
				headers: {
					"content-type": "application/json",
					"x-csrf-token": csrfToken,
				},
				body: JSON.stringify({
					client_session_id: upload.client_session_id,
					chunks: batch.map(stripStoreFields),
					complete: finalBatch,
				}),
			});

			if (!response.ok) return;

			const result = await response.json();
			const batchIndexes = new Set(batch.map((chunk) => chunk.chunk_index));
			const acceptedIndexes = Array.isArray(result.accepted_indexes)
				? [
						...new Set(
							result.accepted_indexes.filter((index) =>
								batchIndexes.has(index),
							),
						),
					]
				: [];

			if (acceptedIndexes.length === 0) return;

			await store.deleteTraceChunks(upload.client_session_id, acceptedIndexes);

			if (acceptedIndexes.length !== batch.length) return;

			if (finalBatch) {
				if (result.complete === true) {
					await store.completeTraceUpload(upload.client_session_id);
				}
				return;
			}
		}
	}

	async function drainReadyUploads() {
		const uploads = await store.listReadyTraceUploads();

		for (const upload of uploads) {
			await drainUpload(upload);
		}
	}

	return {
		drain() {
			if (inFlight) return inFlight;

			inFlight = drainReadyUploads()
				.catch(() => undefined)
				.finally(() => {
					inFlight = null;
				});

			return inFlight;
		},
	};
}

function stripStoreFields(chunk) {
	const { client_session_id: _clientSessionId, ...requestChunk } = chunk;
	return requestChunk;
}
