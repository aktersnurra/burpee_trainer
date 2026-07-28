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
  };
}

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

test("completing an empty trace upload removes its ready marker", async () => {
  const store = createSessionStore(memoryEngine());
  await store.markTraceReady("session-1", 99);

  assert.equal(await store.hasTraceChunks("session-1"), false);
  await store.completeTraceUpload("session-1");
  assert.deepEqual(await store.listReadyTraceUploads(), []);
});

test("discard removes draft, chunks, and upload marker", async () => {
  const store = createSessionStore(memoryEngine());
  await store.saveDraft({
    client_session_id: "session-1",
    plan_id: 7,
    program_hash: "abc",
  });
  await store.appendTraceChunk("session-1", {
    chunk_index: 0,
    payload: {},
  });
  await store.markTraceReady("session-1", 99);

  await store.discardSession("session-1");

  assert.equal(await store.loadDraft({ planId: 7, programHash: "abc" }), null);
  assert.deepEqual(await store.listTraceChunks("session-1"), []);
  assert.deepEqual(await store.listReadyTraceUploads(), []);
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
