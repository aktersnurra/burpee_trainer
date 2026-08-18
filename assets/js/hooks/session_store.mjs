const DATABASE = "burpee-session-runtime";
const VERSION = 2;
const DRAFTS = "completion_drafts";
const LIFECYCLE_COMMANDS = "lifecycle_commands";
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

    async deleteDraft(clientSessionId) {
      await engine.delete(DRAFTS, clientSessionId);
    },

    loadDraftByClientSessionId(clientSessionId) {
      return engine.get(DRAFTS, clientSessionId);
    },

    async saveLifecycleCommand(command) {
      await engine.put(LIFECYCLE_COMMANDS, command);
    },

    loadLifecycleCommand(clientSessionId) {
      return engine.get(LIFECYCLE_COMMANDS, clientSessionId);
    },

    async deleteLifecycleCommand(clientSessionId) {
      await engine.delete(LIFECYCLE_COMMANDS, clientSessionId);
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
      await engine.completeTraceUpload(clientSessionId);
    },

    async discardSession(clientSessionId) {
      await engine.discardSession(clientSessionId);
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
      if (!database.objectStoreNames.contains(LIFECYCLE_COMMANDS)) {
        database.createObjectStore(LIFECYCLE_COMMANDS, {
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

  const compound = (storeNames, operation) =>
    new Promise((resolve, reject) => {
      const transaction = database.transaction(storeNames, "readwrite");
      operation(transaction, reject);
      transaction.oncomplete = () => resolve();
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
    completeTraceUpload(clientSessionId) {
      return compound([CHUNKS, UPLOADS], (transaction, reject) => {
        const chunksRequest = transaction.objectStore(CHUNKS).getAll();
        chunksRequest.onsuccess = () => {
          const hasChunks = chunksRequest.result.some(
            (chunk) => chunk.client_session_id === clientSessionId,
          );
          if (!hasChunks) {
            const deleteRequest = transaction
              .objectStore(UPLOADS)
              .delete(clientSessionId);
            deleteRequest.onerror = () => reject(deleteRequest.error);
          }
        };
        chunksRequest.onerror = () => reject(chunksRequest.error);
      });
    },
    discardSession(clientSessionId) {
      return compound(
        [DRAFTS, LIFECYCLE_COMMANDS, CHUNKS, UPLOADS],
        (transaction, reject) => {
        const draftRequest = transaction
          .objectStore(DRAFTS)
          .delete(clientSessionId);
        const commandRequest = transaction
          .objectStore(LIFECYCLE_COMMANDS)
          .delete(clientSessionId);
        const uploadRequest = transaction
          .objectStore(UPLOADS)
          .delete(clientSessionId);
        const chunksRequest = transaction.objectStore(CHUNKS).getAll();

        for (const request of [
          draftRequest,
          commandRequest,
          uploadRequest,
          chunksRequest,
        ]) {
          request.onerror = () => reject(request.error);
        }
        chunksRequest.onsuccess = () => {
          for (const chunk of chunksRequest.result) {
            if (chunk.client_session_id === clientSessionId) {
              const deleteRequest = transaction
                .objectStore(CHUNKS)
                .delete([clientSessionId, chunk.chunk_index]);
              deleteRequest.onerror = () => reject(deleteRequest.error);
            }
          }
        };
      },
      );
    },
  };
}
