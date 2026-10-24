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

    readTraceChunkBatch(sessionId, takeChunk) {
      return engine.readTraceChunkBatch(sessionId, takeChunk);
    },

    async listReadyTraceUploads() {
      const uploads = await engine.all(UPLOADS);
      return uploads.sort((left, right) => left.session_id - right.session_id);
    },

    deleteTraceChunks(sessionId, indexes) {
      return engine.deleteTraceChunks(sessionId, indexes);
    },

    async settleAcknowledgedFinalUpload(sessionId, acceptedIndexes) {
      await engine.settleAcknowledgedFinalUpload(sessionId, acceptedIndexes);
    },

    // The server deleted the session; nothing of it should be resumed or uploaded.
    discardSession(sessionId, contentHash) {
      return engine.discardSession(sessionId, contentHash);
    },
  };
}

export async function openSessionStore(
  indexedDB = globalThis.indexedDB,
  keyRanges = globalThis.IDBKeyRange,
) {
  if (!indexedDB) {
    throw new Error("IndexedDB is unavailable");
  }

  const database = await openDatabase(indexedDB);
  return createSessionStore(indexedDbEngine(database, keyRanges));
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

function indexedDbEngine(database, keyRanges) {
  const traceRange = (sessionId) =>
    keyRanges.bound([sessionId, 0], [sessionId, Number.MAX_SAFE_INTEGER]);

  // Every result waits for transaction commit, not merely request success.
  const transact = (stores, mode, work) =>
    new Promise((resolve, reject) => {
      const transaction = database.transaction(stores, mode);
      let result;
      const fail = (error) => {
        transaction.abort();
        reject(error);
      };
      transaction.oncomplete = () => resolve(result ?? null);
      transaction.onerror = () => undefined;
      transaction.onabort = () =>
        reject(transaction.error || new Error("Session storage transaction aborted"));
      try {
        work(transaction, (value) => { result = value; }, fail);
      } catch (error) {
        fail(error);
      }
    });

  const run = (store, mode, operation) =>
    transact(store, mode, (transaction, complete) => {
      const request = operation(transaction.objectStore(store));
      request.onsuccess = () => complete(request.result);
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
    readTraceChunkBatch(sessionId, takeChunk) {
      return transact(CHUNKS, "readonly", (transaction, complete, fail) => {
        const request = transaction.objectStore(CHUNKS).openCursor(traceRange(sessionId));
        request.onsuccess = () => {
          const cursor = request.result;
          if (!cursor) {
            complete({ hasMore: false });
            return;
          }
          try {
            // The caller's synchronous byte/count predicate stops with one lookahead.
            if (takeChunk(cursor.value)) cursor.continue();
            else complete({ hasMore: true });
          } catch (error) {
            fail(error);
          }
        };
      });
    },
    deleteTraceChunks(sessionId, indexes) {
      return transact(CHUNKS, "readwrite", (transaction) => {
        deleteChunkKeys(transaction.objectStore(CHUNKS), sessionId, indexes);
      });
    },
    discardSession(sessionId, contentHash) {
      return transact([DRAFTS, CHUNKS, UPLOADS], "readwrite", (transaction) => {
        transaction.objectStore(DRAFTS).delete([sessionId, contentHash]);
        transaction.objectStore(CHUNKS).delete(traceRange(sessionId));
        transaction.objectStore(UPLOADS).delete(sessionId);
      });
    },
    finalizeServerCompletion(sessionId, contentHash, clientSessionId) {
      return transact([DRAFTS, CHUNKS, UPLOADS], "readwrite", (transaction, complete) => {
        const request = transaction.objectStore(CHUNKS).count(traceRange(sessionId));
        request.onsuccess = () => {
          const traceReady = request.result > 0;
          if (traceReady) {
            transaction.objectStore(UPLOADS).put({
              session_id: sessionId,
              client_session_id: clientSessionId,
            });
          }
          transaction.objectStore(DRAFTS).delete([sessionId, contentHash]);
          complete({ traceReady });
        };
      });
    },
    settleAcknowledgedFinalUpload(sessionId, acceptedIndexes) {
      return transact([CHUNKS, UPLOADS], "readwrite", (transaction) => {
        deleteChunkKeys(transaction.objectStore(CHUNKS), sessionId, acceptedIndexes);
        transaction.objectStore(UPLOADS).delete(sessionId);
      });
    },
  };
}

function deleteChunkKeys(store, sessionId, indexes) {
  for (const index of new Set(indexes)) store.delete([sessionId, index]);
}
