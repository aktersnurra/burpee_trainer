import assert from "node:assert/strict";
import test from "node:test";

import { createSessionStore, openSessionStore } from "./session_store.mjs";

function memoryEngine() {
  const stores = new Map();
  const bucket = (name) => {
    if (!stores.has(name)) stores.set(name, new Map());
    return stores.get(name);
  };
  const normalizeKey = (valueKey) =>
    Array.isArray(valueKey) ? JSON.stringify(valueKey) : valueKey;
  const key = (value) =>
    value.chunk_index === undefined
      ? value.client_session_id
      : [value.client_session_id, value.chunk_index];

  return {
    async put(name, value) {
      bucket(name).set(normalizeKey(key(value)), structuredClone(value));
    },
    async get(name, valueKey) {
      const value = bucket(name).get(normalizeKey(valueKey));
      return value === undefined ? null : structuredClone(value);
    },
    async delete(name, valueKey) {
      bucket(name).delete(normalizeKey(valueKey));
    },
    async all(name) {
      return [...bucket(name).values()].map((value) => structuredClone(value));
    },
    async completeTraceUpload(clientSessionId) {
      const hasChunks = [...bucket("pose_trace_chunks").values()].some(
        (chunk) => chunk.client_session_id === clientSessionId,
      );
      if (!hasChunks) bucket("trace_uploads").delete(clientSessionId);
    },
    async discardSession(clientSessionId) {
      bucket("completion_drafts").delete(clientSessionId);
      bucket("lifecycle_commands").delete(clientSessionId);
      bucket("trace_uploads").delete(clientSessionId);
      for (const [chunkKey, chunk] of bucket("pose_trace_chunks")) {
        if (chunk.client_session_id === clientSessionId) {
          bucket("pose_trace_chunks").delete(chunkKey);
        }
      }
    },
  };
}

function fakeIndexedDbHarness() {
  const schema = new Map();
  const transactions = [];

  const request = (result = undefined) => {
    const operation = { result, error: null };
    queueMicrotask(() => operation.onsuccess?.());
    return operation;
  };

  const database = {
    objectStoreNames: {
      contains(name) {
        return schema.has(name);
      },
    },
    createObjectStore(name, options) {
      schema.set(name, options);
    },
    transaction(storeNames, mode) {
      const names = Array.isArray(storeNames) ? storeNames : [storeNames];
      const transaction = {
        names,
        mode,
        error: null,
        objectStore() {
          return {
            put: () => request(),
            get: () => request(null),
            delete: () => request(),
            getAll: () => request([]),
          };
        },
        complete() {
          transaction.oncomplete?.();
        },
        abortWith(error) {
          transaction.error = error;
          transaction.onabort?.();
        },
        errorWith(error) {
          transaction.error = error;
          transaction.onerror?.();
        },
      };
      transactions.push(transaction);
      return transaction;
    },
  };

  return {
    indexedDB: {
      open(name, version) {
        const openRequest = { result: database, error: null, name, version };
        queueMicrotask(() => {
          openRequest.onupgradeneeded?.();
          openRequest.onsuccess?.();
        });
        return openRequest;
      },
    },
    schema,
    transactions,
  };
}

const flushEvents = () => new Promise((resolve) => setImmediate(resolve));

test("loadDraft returns the latest exact plan and program match", async () => {
  const originalNow = Date.now;
  const timestamps = [100, 200, 300];
  Date.now = () => timestamps.shift();

  try {
    const store = createSessionStore(memoryEngine());
    await store.saveDraft({
      client_session_id: "session-1",
      plan_id: 7,
      program_hash: "abc",
      burpee_count_actual: 12,
    });
    await store.saveDraft({
      client_session_id: "session-2",
      plan_id: 7,
      program_hash: "abc",
      burpee_count_actual: 13,
    });
    await store.saveDraft({
      client_session_id: "session-3",
      plan_id: 7,
      program_hash: "different",
      burpee_count_actual: 99,
    });

    const draft = await store.loadDraft({ planId: 7, programHash: "abc" });
    assert.equal(draft.client_session_id, "session-2");
    assert.equal(draft.burpee_count_actual, 13);
    assert.equal(
      await store.loadDraft({ planId: 8, programHash: "abc" }),
      null,
    );
  } finally {
    Date.now = originalNow;
  }
});

test("lifecycle commands and exact UUID drafts are independently addressable", async () => {
  const store = createSessionStore(memoryEngine());
  await store.saveDraft({
    client_session_id: "session-1",
    plan_id: 7,
    program_hash: "abc",
  });
  await store.saveLifecycleCommand({
    client_session_id: "session-1",
    kind: "mark_report_pending",
    payload: { client_session_id: "session-1" },
  });

  assert.equal(
    (await store.loadDraftByClientSessionId("session-1")).program_hash,
    "abc",
  );
  assert.equal(
    (await store.loadLifecycleCommand("session-1")).kind,
    "mark_report_pending",
  );
  await store.deleteLifecycleCommand("session-1");
  assert.equal(await store.loadLifecycleCommand("session-1"), null);
});

test("trace chunks are ordered and acknowledged selectively", async () => {
  const store = createSessionStore(memoryEngine());
  await store.appendTraceChunk("session-1", {
    chunk_index: 2,
    payload: { frame: 2 },
  });
  await store.appendTraceChunk("session-1", {
    chunk_index: 0,
    payload: { frame: 0 },
  });
  await store.appendTraceChunk("session-1", {
    chunk_index: 1,
    payload: { frame: 1 },
  });

  assert.deepEqual(
    (await store.listTraceChunks("session-1")).map(
      (chunk) => chunk.chunk_index,
    ),
    [0, 1, 2],
  );
  assert.equal(await store.hasTraceChunks("session-1"), true);

  await store.deleteTraceChunks("session-1", [0, 2]);
  assert.deepEqual(
    (await store.listTraceChunks("session-1")).map(
      (chunk) => chunk.chunk_index,
    ),
    [1],
  );
  assert.equal(await store.hasTraceChunks("other-session"), false);
});

test("saved sessions become ready for trace upload", async () => {
  const store = createSessionStore(memoryEngine());
  await store.markTraceReady("session-2", 100);
  await store.markTraceReady("session-1", 99);

  assert.deepEqual(await store.listReadyTraceUploads(), [
    { client_session_id: "session-1", session_id: 99 },
    { client_session_id: "session-2", session_id: 100 },
  ]);
});

test("completeTraceUpload delegates one atomic engine operation", async () => {
  const calls = [];
  const store = createSessionStore({
    async completeTraceUpload(clientSessionId) {
      calls.push(clientSessionId);
    },
    all() {
      assert.fail("completeTraceUpload must not list stores separately");
    },
    delete() {
      assert.fail("completeTraceUpload must not delete separately");
    },
  });

  await store.completeTraceUpload("session-1");

  assert.deepEqual(calls, ["session-1"]);
});

test("discardSession delegates one atomic engine operation", async () => {
  const calls = [];
  const store = createSessionStore({
    async discardSession(clientSessionId) {
      calls.push(clientSessionId);
    },
    all() {
      assert.fail("discardSession must not list stores separately");
    },
    delete() {
      assert.fail("discardSession must not delete separately");
    },
  });

  await store.discardSession("session-1");

  assert.deepEqual(calls, ["session-1"]);
});

test("completing an empty trace upload removes its ready marker", async () => {
  const store = createSessionStore(memoryEngine());
  await store.markTraceReady("session-1", 99);

  assert.equal(await store.hasTraceChunks("session-1"), false);
  await store.completeTraceUpload("session-1");
  assert.deepEqual(await store.listReadyTraceUploads(), []);
});

test("discard removes draft, lifecycle command, chunks, and upload marker", async () => {
  const store = createSessionStore(memoryEngine());
  await store.saveDraft({
    client_session_id: "session-1",
    plan_id: 7,
    program_hash: "abc",
  });
  await store.saveLifecycleCommand({
    client_session_id: "session-1",
    kind: "mark_report_pending",
    payload: { client_session_id: "session-1" },
  });
  await store.appendTraceChunk("session-1", {
    chunk_index: 0,
    payload: {},
  });
  await store.markTraceReady("session-1", 99);

  await store.discardSession("session-1");

  assert.equal(await store.loadDraft({ planId: 7, programHash: "abc" }), null);
  assert.equal(await store.loadLifecycleCommand("session-1"), null);
  assert.deepEqual(await store.listTraceChunks("session-1"), []);
  assert.deepEqual(await store.listReadyTraceUploads(), []);
});

test("IndexedDB adapter creates key paths and commits compound operations atomically", async () => {
  const fake = fakeIndexedDbHarness();
  const store = await openSessionStore(fake.indexedDB);

  assert.deepEqual(
    [...fake.schema],
    [
      ["completion_drafts", { keyPath: "client_session_id" }],
      ["lifecycle_commands", { keyPath: "client_session_id" }],
      ["pose_trace_chunks", { keyPath: ["client_session_id", "chunk_index"] }],
      ["trace_uploads", { keyPath: "client_session_id" }],
    ],
  );

  let completionResolved = false;
  const completion = store.completeTraceUpload("session-1").then(() => {
    completionResolved = true;
  });
  await flushEvents();
  const completionTransaction = fake.transactions.at(-1);
  assert.deepEqual(completionTransaction.names, [
    "pose_trace_chunks",
    "trace_uploads",
  ]);
  assert.equal(completionTransaction.mode, "readwrite");
  assert.equal(completionResolved, false);
  completionTransaction.complete();
  await completion;
  assert.equal(completionResolved, true);

  let discardResolved = false;
  const discard = store.discardSession("session-1").then(() => {
    discardResolved = true;
  });
  await flushEvents();
  const discardTransaction = fake.transactions.at(-1);
  assert.deepEqual(discardTransaction.names, [
    "completion_drafts",
    "lifecycle_commands",
    "pose_trace_chunks",
    "trace_uploads",
  ]);
  assert.equal(discardTransaction.mode, "readwrite");
  assert.equal(discardResolved, false);
  discardTransaction.complete();
  await discard;
  assert.equal(discardResolved, true);
});

test("IndexedDB compound operations reject transaction aborts and errors", async () => {
  const fake = fakeIndexedDbHarness();
  const store = await openSessionStore(fake.indexedDB);

  const aborted = store.completeTraceUpload("session-1");
  await flushEvents();
  const abortError = new Error("transaction aborted");
  fake.transactions.at(-1).abortWith(abortError);
  await assert.rejects(aborted, abortError);

  const failed = store.discardSession("session-1");
  await flushEvents();
  const transactionError = new Error("transaction failed");
  fake.transactions.at(-1).errorWith(transactionError);
  await assert.rejects(failed, transactionError);
});

test("openSessionStore rejects when IndexedDB is unavailable", async () => {
  await assert.rejects(
    openSessionStore(undefined),
    new Error("IndexedDB is unavailable"),
  );
});

test("deleteDraft removes only the selected completion", async () => {
  const store = createSessionStore(memoryEngine());
  await store.saveDraft({
    client_session_id: "session-1",
    plan_id: 7,
    program_hash: "abc",
  });
  await store.saveDraft({
    client_session_id: "session-2",
    plan_id: 8,
    program_hash: "def",
  });

  await store.deleteDraft("session-1");

  assert.equal(await store.loadDraft({ planId: 7, programHash: "abc" }), null);
  assert.equal(
    (await store.loadDraft({ planId: 8, programHash: "def" }))
      .client_session_id,
    "session-2",
  );
});
