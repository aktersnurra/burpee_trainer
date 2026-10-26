const DATABASE = "burpee-session-runtime";
const VERSION = 2;
const DRAFTS = "completion_drafts";
const CHUNKS = "pose_trace_chunks";
const UPLOADS = "trace_uploads";

export function createSessionStore(engine) {
  const captureOffsets = new Map();
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

    async appendTraceChunk(sessionId, clientSessionId, chunk, captureId) {
      if (captureId) {
        const key = `${sessionId}:${captureId}`;
        if (!captureOffsets.has(key)) {
          const offset = engine.nextTraceChunkIndex(sessionId).catch((error) => {
            captureOffsets.delete(key);
            throw error;
          });
          captureOffsets.set(key, offset);
        }
        chunk = {
          ...chunk,
          chunk_index: chunk.chunk_index + await captureOffsets.get(key),
          // A reload starts a new camera clock, not a seamless continuation.
          payload: { ...chunk.payload, capture_id: captureId },
        };
      }
      await engine.put(CHUNKS, {
        ...chunk,
        session_id: sessionId,
        client_session_id: clientSessionId,
      });
    },

    readTraceChunkBatch(sessionId, takeChunk) {
      return engine.readTraceChunkBatch(sessionId, takeChunk);
    },

    countTraceChunks(sessionId) {
      return engine.countTraceChunks(sessionId);
    },

    async listReadyTraceUploads() {
      const uploads = await engine.listReadyTraceUploads();
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
    nextTraceChunkIndex(sessionId) {
      return transact(CHUNKS, "readonly", (transaction, complete) => {
        const request = transaction.objectStore(CHUNKS).openCursor(traceRange(sessionId), "prev");
        request.onsuccess = () => complete(request.result ? request.result.value.chunk_index + 1 : 0);
      });
    },
    countTraceChunks(sessionId) {
      return run(CHUNKS, "readonly", (objectStore) => objectStore.count(traceRange(sessionId)));
    },
    // Queued uploads, plus every session whose chunks were saved but never queued:
    // finishing the workout failed locally. The server accepts those only once the
    // session is completed there.
    listReadyTraceUploads() {
      return transact([CHUNKS, UPLOADS], "readonly", (transaction, complete, fail) => {
        // An exception in a handler aborts the transaction with a generic error; report the real one.
        const guarded = (handler) => () => {
          try {
            handler();
          } catch (error) {
            fail(error);
          }
        };
        const chunks = transaction.objectStore(CHUNKS);
        const queued = transaction.objectStore(UPLOADS).getAll();
        queued.onsuccess = guarded(() => {
          const uploads = queued.result;
          complete(uploads);
          const known = new Set(uploads.map((upload) => upload.session_id));
          const keys = chunks.getAllKeys();
          keys.onsuccess = guarded(() => {
            // Keys only; one chunk is read per unqueued session, for its client ID. Older
            // builds keyed chunks by a client UUID; the server cannot place those.
            const firstKeys = new Map();
            for (const key of keys.result) {
              const sessionId = key[0];
              if (Number.isInteger(sessionId) && !known.has(sessionId) && !firstKeys.has(sessionId)) {
                firstKeys.set(sessionId, key);
              }
            }
            for (const [sessionId, key] of firstKeys) {
              const chunk = chunks.get(key);
              chunk.onsuccess = guarded(() => {
                uploads.push({ session_id: sessionId, client_session_id: chunk.result.client_session_id });
              });
            }
          });
        });
      });
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
            const last = transaction.objectStore(CHUNKS).openCursor(traceRange(sessionId), "prev");
            last.onsuccess = () => {
              transaction.objectStore(UPLOADS).put({
                session_id: sessionId,
                client_session_id: clientSessionId,
                expected_chunk_count: last.result.value.chunk_index + 1,
              });
            };
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
