const DATABASE = "burpee-session-runtime";
const VERSION = 3;
const DRAFTS = "completion_drafts";
const CHUNKS = "pose_trace_chunks";
const UPLOADS = "trace_uploads";
const SCHEMA = [
  [DRAFTS, ["session_id", "content_hash"]],
  [CHUNKS, ["session_id", "chunk_index"]],
  [UPLOADS, "session_id"],
];

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

    // The server no longer has the session; its trace has nowhere to go.
    deleteTrace(sessionId) {
      return engine.deleteTrace(sessionId);
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
      for (const [name, keyPath] of SCHEMA) {
        // Version 1 stores predate the session runtime; nothing in them is resumable.
        if (event.oldVersion < 2 && database.objectStoreNames.contains(name)) {
          database.deleteObjectStore(name);
        }
        if (!database.objectStoreNames.contains(name)) {
          database.createObjectStore(name, { keyPath });
        } else if (!sameKeyPath(request.transaction.objectStore(name).keyPath, keyPath)) {
          rekeyStore(database, request.transaction, name, keyPath);
        }
      }
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

function sameKeyPath(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

// Version 2 databases created before server session IDs keyed every store by client
// ID. Records are copied one at a time through a scratch store (a trace is large), then
// back under the current key path. Records from that era carry only the client ID;
// uploads find their sessions by it. A record that still has no key is dropped.
function rekeyStore(database, transaction, name, keyPath) {
  const scratchName = `${name}_rekey`;
  const scratch = database.createObjectStore(scratchName, { autoIncrement: true });
  copyRecords(transaction.objectStore(name), scratch, (record) => record, () => {
    database.deleteObjectStore(name);
    const target = database.createObjectStore(name, { keyPath });
    copyRecords(
      transaction.objectStore(scratchName),
      target,
      (record) => {
        const rekeyed = { ...record, session_id: record.session_id ?? record.client_session_id };
        return keyable(rekeyed, keyPath) ? rekeyed : null;
      },
      () => database.deleteObjectStore(scratchName),
    );
  });
}

function copyRecords(source, target, convert, done) {
  const cursor = source.openCursor();
  cursor.onsuccess = () => {
    const current = cursor.result;
    if (!current) {
      done();
      return;
    }
    const record = convert(current.value);
    if (record) target.put(record);
    current.continue();
  };
}

function keyable(record, keyPath) {
  return [keyPath].flat().every((field) => {
    const value = record[field];
    return typeof value === "string" || (typeof value === "number" && !Number.isNaN(value));
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
            // Keys only; one chunk is read per unqueued session, for its client ID. A
            // database created before server session IDs (same version, older key paths)
            // keys every chunk by its client ID; the server finds those sessions by it.
            const firstKeys = new Map();
            for (const key of keys.result) {
              if (!known.has(key[0]) && !firstKeys.has(key[0])) firstKeys.set(key[0], key);
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
    deleteTrace(sessionId) {
      return transact([CHUNKS, UPLOADS], "readwrite", (transaction) => {
        transaction.objectStore(CHUNKS).delete(traceRange(sessionId));
        transaction.objectStore(UPLOADS).delete(sessionId);
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
