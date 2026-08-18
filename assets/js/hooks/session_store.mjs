const DATABASE = "burpee-session-runtime";
const VERSION = 2;
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

    async loadDraft({ sessionId, contentHash }) {
      const drafts = await engine.all(DRAFTS);
      const matches = drafts.filter(
        (draft) =>
          draft.session_id === sessionId && draft.content_hash === contentHash,
      );

      return (
        matches.sort(
          (left, right) => right.updated_at_ms - left.updated_at_ms,
        )[0] || null
      );
    },

    async finalizeServerCompletion(sessionId, contentHash, clientSessionId) {
      return engine.finalizeServerCompletion(
        sessionId,
        contentHash,
        clientSessionId,
      );
    },

    async appendTraceChunk(sessionId, clientSessionId, chunk) {
      await engine.put(CHUNKS, {
        ...chunk,
        session_id: sessionId,
        client_session_id: clientSessionId,
      });
    },

    async listTraceChunks(sessionId) {
      const chunks = await engine.all(CHUNKS);
      return chunks
        .filter((chunk) => chunk.session_id === sessionId)
        .sort((left, right) => left.chunk_index - right.chunk_index);
    },

    async listReadyTraceUploads() {
      const uploads = await engine.all(UPLOADS);
      return uploads.sort((left, right) => left.session_id - right.session_id);
    },

    async deleteTraceChunks(sessionId, indexes) {
      const chunks = await this.listTraceChunks(sessionId);
      const selected = new Set(indexes);
      await Promise.all(
        chunks
          .filter((chunk) => selected.has(chunk.chunk_index))
          .map((chunk) =>
            engine.delete(CHUNKS, [chunk.session_id, chunk.chunk_index]),
          ),
      );
    },

    async settleAcknowledgedFinalUpload(sessionId, acceptedIndexes) {
      await engine.settleAcknowledgedFinalUpload(sessionId, acceptedIndexes);
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
    let abandoned = false;

    request.onupgradeneeded = (event) => {
      const database = request.result;
      if (event.oldVersion < VERSION) {
        for (const name of [DRAFTS, CHUNKS, UPLOADS]) {
          if (database.objectStoreNames.contains(name)) {
            database.deleteObjectStore(name);
          }
        }
      }

      database.createObjectStore(DRAFTS, {
        keyPath: ["session_id", "content_hash"],
      });
      database.createObjectStore(CHUNKS, {
        keyPath: ["session_id", "chunk_index"],
      });
      database.createObjectStore(UPLOADS, {
        keyPath: "session_id",
      });
    };
    request.onblocked = () => {
      abandoned = true;
      const error = new Error(
        "Session storage is blocked. Close other Burpee Trainer tabs and retry.",
      );
      error.code = "indexeddb_blocked";
      reject(error);
    };
    request.onsuccess = () => {
      if (abandoned) {
        request.result.close();
      } else {
        resolve(request.result);
      }
    };
    request.onerror = () => {
      if (!abandoned) reject(request.error);
    };
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
    finalizeServerCompletion(sessionId, contentHash, clientSessionId) {
      return new Promise((resolve, reject) => {
        const transaction = database.transaction(
          [DRAFTS, CHUNKS, UPLOADS],
          "readwrite",
        );
        let traceReady = false;
        const chunksRequest = transaction.objectStore(CHUNKS).getAll();

        chunksRequest.onsuccess = () => {
          traceReady = chunksRequest.result.some(
            (chunk) => chunk.session_id === sessionId,
          );

          if (traceReady) {
            transaction.objectStore(UPLOADS).put({
              session_id: sessionId,
              client_session_id: clientSessionId,
            });
          }

          transaction.objectStore(DRAFTS).delete([sessionId, contentHash]);
        };
        transaction.oncomplete = () => resolve({ traceReady });
        transaction.onerror = () => undefined;
        transaction.onabort = () =>
          reject(
            transaction.error || new Error("Session finalization aborted"),
          );
      });
    },
    settleAcknowledgedFinalUpload(sessionId, acceptedIndexes) {
      return new Promise((resolve, reject) => {
        const transaction = database.transaction(
          [CHUNKS, UPLOADS],
          "readwrite",
        );
        const chunkStore = transaction.objectStore(CHUNKS);

        for (const index of new Set(acceptedIndexes)) {
          chunkStore.delete([sessionId, index]);
        }
        transaction.objectStore(UPLOADS).delete(sessionId);

        transaction.oncomplete = () => resolve();
        transaction.onerror = () => undefined;
        transaction.onabort = () =>
          reject(
            transaction.error || new Error("Trace upload settlement aborted"),
          );
      });
    },
  };
}
