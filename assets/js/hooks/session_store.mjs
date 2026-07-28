const DATABASE = "burpee-session-runtime";
const VERSION = 1;
const DRAFTS = "completion_drafts";
const CHUNKS = "pose_trace_chunks";
const UPLOADS = "trace_uploads";

export function createSessionStore(engine) {
	return {
		async saveDraft(draft) {
			await engine.put(DRAFTS, {
				...draft,
				updated_at_ms: Date.now(),
			});
		},

		async loadDraft({ planId, programHash }) {
			const drafts = await engine.all(DRAFTS);
			const matches = drafts.filter(
				(draft) =>
					draft.plan_id === planId && draft.program_hash === programHash,
			);

			return (
				matches.sort(
					(left, right) => right.updated_at_ms - left.updated_at_ms,
				)[0] || null
			);
		},

		async deleteDraft(clientSessionId) {
			await engine.delete(DRAFTS, clientSessionId);
		},

		async appendTraceChunk(clientSessionId, chunk) {
			await engine.put(CHUNKS, {
				...chunk,
				client_session_id: clientSessionId,
			});
		},

		async listTraceChunks(clientSessionId) {
			const chunks = await engine.all(CHUNKS);
			return chunks
				.filter((chunk) => chunk.client_session_id === clientSessionId)
				.sort((left, right) => left.chunk_index - right.chunk_index);
		},

		async markTraceReady(clientSessionId, sessionId) {
			await engine.put(UPLOADS, {
				client_session_id: clientSessionId,
				session_id: sessionId,
			});
		},

		async listReadyTraceUploads() {
			const uploads = await engine.all(UPLOADS);
			return uploads.sort((left, right) =>
				left.client_session_id.localeCompare(right.client_session_id),
			);
		},

		async hasTraceChunks(clientSessionId) {
			const chunks = await engine.all(CHUNKS);
			return chunks.some(
				(chunk) => chunk.client_session_id === clientSessionId,
			);
		},

		async deleteTraceChunks(clientSessionId, indexes) {
			await Promise.all(
				indexes.map((index) => engine.delete(CHUNKS, [clientSessionId, index])),
			);
		},

		async completeTraceUpload(clientSessionId) {
			if (!(await this.hasTraceChunks(clientSessionId))) {
				await engine.delete(UPLOADS, clientSessionId);
			}
		},

		async discardSession(clientSessionId) {
			const chunks = await this.listTraceChunks(clientSessionId);
			await Promise.all([
				engine.delete(DRAFTS, clientSessionId),
				engine.delete(UPLOADS, clientSessionId),
				...chunks.map((chunk) =>
					engine.delete(CHUNKS, [clientSessionId, chunk.chunk_index]),
				),
			]);
		},
	};
}

export async function openSessionStore(indexedDB = globalThis.indexedDB) {
	if (!indexedDB) {
		throw new Error("IndexedDB is unavailable");
	}

	const database = await openDatabase(indexedDB);
	return createSessionStore(indexedDbEngine(database));
}

function openDatabase(indexedDB) {
	return new Promise((resolve, reject) => {
		const request = indexedDB.open(DATABASE, VERSION);

		request.onupgradeneeded = () => {
			const database = request.result;
			if (!database.objectStoreNames.contains(DRAFTS)) {
				database.createObjectStore(DRAFTS, {
					keyPath: "client_session_id",
				});
			}
			if (!database.objectStoreNames.contains(CHUNKS)) {
				database.createObjectStore(CHUNKS, {
					keyPath: ["client_session_id", "chunk_index"],
				});
			}
			if (!database.objectStoreNames.contains(UPLOADS)) {
				database.createObjectStore(UPLOADS, {
					keyPath: "client_session_id",
				});
			}
		};
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
	});
}

function indexedDbEngine(database) {
	const run = (storeName, mode, operation) =>
		new Promise((resolve, reject) => {
			const transaction = database.transaction(storeName, mode);
			const store = transaction.objectStore(storeName);
			const request = operation(store);
			let result;

			request.onsuccess = () => {
				result = request.result;
			};
			request.onerror = () => reject(request.error);
			transaction.oncomplete = () => resolve(result ?? null);
			transaction.onerror = () => reject(transaction.error);
			transaction.onabort = () => reject(transaction.error);
		});

	return {
		async put(store, value) {
			await run(store, "readwrite", (objectStore) => objectStore.put(value));
		},
		get(store, key) {
			return run(store, "readonly", (objectStore) => objectStore.get(key));
		},
		async delete(store, key) {
			await run(store, "readwrite", (objectStore) => objectStore.delete(key));
		},
		all(store) {
			return run(store, "readonly", (objectStore) => objectStore.getAll());
		},
	};
}
