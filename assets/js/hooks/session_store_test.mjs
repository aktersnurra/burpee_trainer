import assert from "node:assert/strict";
import test from "node:test";

import { createSessionStore, openSessionStore } from "./session_store.mjs";

function memoryEngine() {
  const stores = new Map();
  const bucket = (name) => {
    if (!stores.has(name)) stores.set(name, new Map());
    return stores.get(name);
  };
  const normalize = (key) => (Array.isArray(key) ? JSON.stringify(key) : key);
  const keyFor = (name, value) => {
    if (name === "completion_drafts")
      return [value.session_id, value.content_hash];
    if (name === "pose_trace_chunks")
      return [value.session_id, value.chunk_index];
    return value.session_id;
  };

  return {
    async put(name, value) {
      bucket(name).set(normalize(keyFor(name, value)), structuredClone(value));
    },
    async delete(name, key) {
      bucket(name).delete(normalize(key));
    },
    async all(name) {
      return [...bucket(name).values()].map((value) => structuredClone(value));
    },
    async finalizeServerCompletion(sessionId, contentHash, clientSessionId) {
      const chunks = [...bucket("pose_trace_chunks").values()];
      const traceReady = chunks.some((chunk) => chunk.session_id === sessionId);
      if (traceReady) {
        bucket("trace_uploads").set(sessionId, {
          session_id: sessionId,
          client_session_id: clientSessionId,
        });
      }
      bucket("completion_drafts").delete(normalize([sessionId, contentHash]));
      return { traceReady };
    },
    async settleAcknowledgedFinalUpload(sessionId, indexes) {
      for (const index of indexes) {
        bucket("pose_trace_chunks").delete(normalize([sessionId, index]));
      }
      bucket("trace_uploads").delete(sessionId);
    },
  };
}

function fakeIndexedDbHarness({ oldVersion = 0, initialSchema = [] } = {}) {
  const schema = new Map(initialSchema);
  const deleted = [];
  const database = {
    objectStoreNames: {
      contains(name) {
        return schema.has(name);
      },
    },
    deleteObjectStore(name) {
      deleted.push(name);
      schema.delete(name);
    },
    createObjectStore(name, options) {
      schema.set(name, options);
    },
    transaction() {
      throw new Error("schema tests must not open a transaction");
    },
  };

  return {
    indexedDB: {
      open(name, version) {
        const request = { result: database, error: null, name, version };
        queueMicrotask(() => {
          request.onupgradeneeded?.({ oldVersion, newVersion: version });
          request.onsuccess?.();
        });
        return request;
      },
    },
    schema,
    deleted,
  };
}

function statefulIndexedDbHarness({ failDeleteKey = null } = {}) {
  let remainingForcedFailures = failDeleteKey === null ? 0 : 1;
  const storeNames = [
    "completion_drafts",
    "pose_trace_chunks",
    "trace_uploads",
  ];
  const committed = new Map(storeNames.map((name) => [name, new Map()]));
  const normalize = (key) => (Array.isArray(key) ? JSON.stringify(key) : key);
  const keyFor = (name, value) => {
    if (name === "completion_drafts") {
      return [value.session_id, value.content_hash];
    }
    if (name === "pose_trace_chunks") {
      return [value.session_id, value.chunk_index];
    }
    return value.session_id;
  };
  const cloneMap = (values) =>
    new Map([...values].map(([key, value]) => [key, structuredClone(value)]));

  const database = {
    objectStoreNames: {
      contains(name) {
        return committed.has(name);
      },
    },
    createObjectStore() {
      throw new Error("version 2 schema already exists");
    },
    deleteObjectStore() {
      throw new Error("version 2 schema must not be replaced");
    },
    transaction(requestedStoreNames, mode) {
      assert.equal(mode, "readwrite");
      const names = Array.isArray(requestedStoreNames)
        ? requestedStoreNames
        : [requestedStoreNames];
      const working = new Map(
        names.map((name) => [name, cloneMap(committed.get(name))]),
      );
      let pending = 0;
      let settled = false;
      let completionQueued = false;

      const transaction = {
        error: null,
        objectStore(name) {
          assert.equal(names.includes(name), true);
          const values = working.get(name);

          return {
            getAll() {
              return request(() =>
                [...values.values()].map((value) => structuredClone(value)),
              );
            },
            put(value) {
              return request(() => {
                values.set(
                  normalize(keyFor(name, value)),
                  structuredClone(value),
                );
                return keyFor(name, value);
              });
            },
            delete(key) {
              const normalized = normalize(key);
              return request(
                () => {
                  values.delete(normalized);
                  return undefined;
                },
                failDeleteKey === `${name}:${normalized}` &&
                  remainingForcedFailures-- > 0,
              );
            },
          };
        },
      };

      function request(operation, fail = false) {
        const indexedDbRequest = { result: undefined, error: null };
        pending += 1;
        queueMicrotask(() => {
          if (settled) return;

          if (fail) {
            indexedDbRequest.error = new Error("forced transaction abort");
            transaction.error = indexedDbRequest.error;
            indexedDbRequest.onerror?.();
            settled = true;
            queueMicrotask(() => transaction.onabort?.());
            return;
          }

          indexedDbRequest.result = operation();
          indexedDbRequest.onsuccess?.();
          pending -= 1;
          queueCompletion();
        });
        return indexedDbRequest;
      }

      function queueCompletion() {
        if (completionQueued || settled) return;
        completionQueued = true;
        queueMicrotask(() => {
          completionQueued = false;
          if (settled || pending !== 0) return;
          settled = true;
          for (const name of names) {
            committed.set(name, working.get(name));
          }
          transaction.oncomplete?.();
        });
      }

      return transaction;
    },
  };

  return {
    indexedDB: {
      open() {
        const request = { result: database, error: null };
        queueMicrotask(() => request.onsuccess?.());
        return request;
      },
    },
    seed(name, value) {
      committed
        .get(name)
        .set(normalize(keyFor(name, value)), structuredClone(value));
    },
    values(name) {
      return [...committed.get(name).values()].map((value) =>
        structuredClone(value),
      );
    },
  };
}

test("drafts are keyed only by exact session ID and content hash", async () => {
  const originalNow = Date.now;
  const timestamps = [100, 200, 300, 400];
  Date.now = () => timestamps.shift();
  try {
    const store = createSessionStore(memoryEngine());
    await store.saveDraft({
      session_id: 7,
      content_hash: "abc",
      client_session_id: "server-client",
      burpee_count_actual: 12,
    });
    await store.saveDraft({
      session_id: 7,
      content_hash: "def",
      client_session_id: "server-client",
      burpee_count_actual: 99,
    });
    await store.saveDraft({
      session_id: 8,
      content_hash: "abc",
      client_session_id: "other-client",
      burpee_count_actual: 50,
    });
    await store.saveDraft({
      plan_id: 7,
      program_hash: "abc",
      client_session_id: "legacy-client",
      burpee_count_actual: 77,
    });

    const draft = await store.loadDraft({ sessionId: 7, contentHash: "abc" });
    assert.equal(draft.burpee_count_actual, 12);
    assert.equal(draft.client_session_id, "server-client");
    assert.equal(
      await store.loadDraft({ sessionId: 8, contentHash: "def" }),
      null,
    );
    assert.equal(
      await store.loadDraft({ sessionId: 7, contentHash: "missing" }),
      null,
    );
  } finally {
    Date.now = originalNow;
  }
});

test("trace chunks and ready uploads carry the same server session and client IDs", async () => {
  const store = createSessionStore(memoryEngine());
  await store.appendTraceChunk(11, "client-11", {
    chunk_index: 2,
    payload: {},
  });
  await store.appendTraceChunk(11, "client-11", {
    chunk_index: 0,
    payload: {},
  });
  await store.finalizeServerCompletion(11, "hash-11", "client-11");

  assert.deepEqual(
    (await store.listTraceChunks(11)).map((chunk) => [
      chunk.session_id,
      chunk.client_session_id,
      chunk.chunk_index,
    ]),
    [
      [11, "client-11", 0],
      [11, "client-11", 2],
    ],
  );
  assert.deepEqual(await store.listReadyTraceUploads(), [
    { session_id: 11, client_session_id: "client-11" },
  ]);

  await store.deleteTraceChunks(11, [0]);
  assert.deepEqual(
    (await store.listTraceChunks(11)).map((chunk) => chunk.chunk_index),
    [2],
  );
});

test("version 2 purges every version 1 store before recreating session schema", async () => {
  const v1 = [
    ["completion_drafts", { keyPath: "client_session_id" }],
    ["pose_trace_chunks", { keyPath: ["client_session_id", "chunk_index"] }],
    ["trace_uploads", { keyPath: "client_session_id" }],
  ];
  const fake = fakeIndexedDbHarness({ oldVersion: 1, initialSchema: v1 });

  await openSessionStore(fake.indexedDB);

  assert.deepEqual(fake.deleted, [
    "completion_drafts",
    "pose_trace_chunks",
    "trace_uploads",
  ]);
  assert.deepEqual(
    [...fake.schema],
    [
      ["completion_drafts", { keyPath: ["session_id", "content_hash"] }],
      ["pose_trace_chunks", { keyPath: ["session_id", "chunk_index"] }],
      ["trace_uploads", { keyPath: "session_id" }],
    ],
  );
});

test("a fresh version 2 database creates the session schema", async () => {
  const fake = fakeIndexedDbHarness();
  await openSessionStore(fake.indexedDB);

  assert.deepEqual(fake.deleted, []);
  assert.deepEqual(
    [...fake.schema],
    [
      ["completion_drafts", { keyPath: ["session_id", "content_hash"] }],
      ["pose_trace_chunks", { keyPath: ["session_id", "chunk_index"] }],
      ["trace_uploads", { keyPath: "session_id" }],
    ],
  );
});

test("openSessionStore rejects when IndexedDB is unavailable", async () => {
  await assert.rejects(
    openSessionStore(undefined),
    new Error("IndexedDB is unavailable"),
  );
});

test("a blocked version upgrade rejects deterministically and closes a later success", async () => {
  let request;
  let closeCalls = 0;
  const database = { close: () => (closeCalls += 1) };
  const indexedDB = {
    open() {
      request = { result: database, error: null };
      queueMicrotask(() => request.onblocked?.());
      return request;
    },
  };

  await assert.rejects(
    openSessionStore(indexedDB),
    /Close other Burpee Trainer tabs and retry/,
  );

  request.onsuccess();
  assert.equal(closeCalls, 1);
});

test("server completion finalization atomically publishes the exact marker and deletes only the exact draft", async () => {
  const fake = statefulIndexedDbHarness();
  fake.seed("completion_drafts", {
    session_id: 41,
    content_hash: "hash-1",
    client_session_id: "client-41",
  });
  fake.seed("completion_drafts", {
    session_id: 41,
    content_hash: "other-hash",
    client_session_id: "client-41",
  });
  fake.seed("completion_drafts", {
    session_id: 42,
    content_hash: "hash-1",
    client_session_id: "client-42",
  });
  fake.seed("pose_trace_chunks", {
    session_id: 41,
    client_session_id: "client-41",
    chunk_index: 0,
  });
  fake.seed("pose_trace_chunks", {
    session_id: 42,
    client_session_id: "client-42",
    chunk_index: 0,
  });
  const store = await openSessionStore(fake.indexedDB);

  assert.deepEqual(
    await store.finalizeServerCompletion(41, "hash-1", "client-41"),
    { traceReady: true },
  );
  assert.deepEqual(fake.values("completion_drafts"), [
    {
      session_id: 41,
      content_hash: "other-hash",
      client_session_id: "client-41",
    },
    {
      session_id: 42,
      content_hash: "hash-1",
      client_session_id: "client-42",
    },
  ]);
  assert.deepEqual(fake.values("trace_uploads"), [
    { session_id: 41, client_session_id: "client-41" },
  ]);
  assert.deepEqual(
    fake
      .values("pose_trace_chunks")
      .map((chunk) => [chunk.session_id, chunk.chunk_index]),
    [
      [41, 0],
      [42, 0],
    ],
  );
});

test("final acknowledgement atomically deletes exactly accepted chunks and its marker", async () => {
  const fake = statefulIndexedDbHarness();
  for (const value of [
    { session_id: 41, client_session_id: "client-41", chunk_index: 0 },
    { session_id: 41, client_session_id: "client-41", chunk_index: 1 },
    { session_id: 41, client_session_id: "client-41", chunk_index: 2 },
    { session_id: 42, client_session_id: "client-42", chunk_index: 0 },
  ]) {
    fake.seed("pose_trace_chunks", value);
  }
  fake.seed("trace_uploads", {
    session_id: 41,
    client_session_id: "client-41",
  });
  fake.seed("trace_uploads", {
    session_id: 42,
    client_session_id: "client-42",
  });
  const store = await openSessionStore(fake.indexedDB);

  await store.settleAcknowledgedFinalUpload(41, [0, 2]);

  assert.deepEqual(
    fake
      .values("pose_trace_chunks")
      .map((chunk) => [chunk.session_id, chunk.chunk_index]),
    [
      [41, 1],
      [42, 0],
    ],
  );
  assert.deepEqual(fake.values("trace_uploads"), [
    { session_id: 42, client_session_id: "client-42" },
  ]);
});

test("aborted final acknowledgement leaves chunks and marker retryable together", async () => {
  const fake = statefulIndexedDbHarness({
    failDeleteKey: "trace_uploads:41",
  });
  for (const chunkIndex of [0, 1]) {
    fake.seed("pose_trace_chunks", {
      session_id: 41,
      client_session_id: "client-41",
      chunk_index: chunkIndex,
    });
  }
  fake.seed("trace_uploads", {
    session_id: 41,
    client_session_id: "client-41",
  });
  const store = await openSessionStore(fake.indexedDB);

  await assert.rejects(
    store.settleAcknowledgedFinalUpload(41, [0, 1]),
    /forced transaction abort/,
  );
  assert.deepEqual(
    fake.values("pose_trace_chunks").map((chunk) => chunk.chunk_index),
    [0, 1],
  );
  assert.deepEqual(fake.values("trace_uploads"), [
    { session_id: 41, client_session_id: "client-41" },
  ]);

  await store.settleAcknowledgedFinalUpload(41, [0, 1]);
  assert.deepEqual(fake.values("pose_trace_chunks"), []);
  assert.deepEqual(fake.values("trace_uploads"), []);
});

test("an aborted server completion finalization commits neither marker nor draft deletion", async () => {
  const draftKey = JSON.stringify([41, "hash-1"]);
  const fake = statefulIndexedDbHarness({
    failDeleteKey: `completion_drafts:${draftKey}`,
  });
  fake.seed("completion_drafts", {
    session_id: 41,
    content_hash: "hash-1",
    client_session_id: "client-41",
  });
  fake.seed("pose_trace_chunks", {
    session_id: 41,
    client_session_id: "client-41",
    chunk_index: 0,
  });
  const store = await openSessionStore(fake.indexedDB);

  await assert.rejects(
    store.finalizeServerCompletion(41, "hash-1", "client-41"),
    /forced transaction abort/,
  );
  assert.deepEqual(fake.values("completion_drafts"), [
    {
      session_id: 41,
      content_hash: "hash-1",
      client_session_id: "client-41",
    },
  ]);
  assert.deepEqual(fake.values("trace_uploads"), []);
  assert.equal(fake.values("pose_trace_chunks").length, 1);
});
