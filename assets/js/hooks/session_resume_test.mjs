import assert from "node:assert/strict";
import test from "node:test";

import { createSessionStore } from "./session_store.mjs";

function memoryEngine() {
  const buckets = new Map();
  const bucket = (name) => {
    if (!buckets.has(name)) buckets.set(name, new Map());
    return buckets.get(name);
  };
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
  };
}

function draft(overrides = {}) {
  return {
    session_id: 41,
    content_hash: "hash-41",
    client_session_id: "server-client-41",
    burpee_count_actual: 9,
    ...overrides,
  };
}

test("normal resume loads only the exact server session and content hash", async () => {
  const store = createSessionStore(memoryEngine());
  await store.saveDraft(draft());
  await store.saveDraft(
    draft({ content_hash: "stale-hash", burpee_count_actual: 99 }),
  );

  const resumed = await store.loadDraft({
    sessionId: 41,
    contentHash: "hash-41",
  });
  assert.equal(resumed.session_id, 41);
  assert.equal(resumed.content_hash, "hash-41");
  assert.equal(resumed.client_session_id, "server-client-41");
  assert.equal(resumed.burpee_count_actual, 9);
  assert.equal(typeof resumed.updated_at_ms, "number");
  assert.equal(
    await store.loadDraft({ sessionId: 41, contentHash: "missing-hash" }),
    null,
  );
});

test("a local draft for a missing server session cannot attach to another session", async () => {
  const store = createSessionStore(memoryEngine());
  await store.saveDraft(draft({ session_id: 404, content_hash: "missing" }));

  assert.equal(
    await store.loadDraft({ sessionId: 41, contentHash: "hash-41" }),
    null,
  );
});

test("stale chunks and upload markers for a missing session are not returned for resume", async () => {
  const store = createSessionStore(memoryEngine());
  await store.appendTraceChunk(404, "missing-client", {
    chunk_index: 0,
    payload: { stale: true },
  });
  await store.finalizeServerCompletion(404, "missing", "missing-client");

  assert.deepEqual(await store.listTraceChunks(41), []);
  assert.deepEqual(
    (await store.listReadyTraceUploads()).filter(
      (upload) => upload.session_id === 41,
    ),
    [],
  );
});
