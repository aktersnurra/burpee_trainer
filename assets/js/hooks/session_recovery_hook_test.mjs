import assert from "node:assert/strict";
import test from "node:test";

import SessionRecoveryHook from "./session_recovery_hook.js";

class FakeElement {
  constructor(id) {
    this.id = id;
    this.value = "";
    this.dataset = {};
    this.listeners = new Map();
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  dispatchEvent(event) {
    this.listeners.get(event.type)?.(event);
    return true;
  }
}

function draft(clientSessionId = "session-1") {
  return {
    client_session_id: clientSessionId,
    burpee_count_actual: 12,
    duration_sec_actual: 88,
    mood: 1,
    tags: ["great_energy", "tired"],
    note_post: "Recovered locally",
  };
}

function mountedHook({
  status,
  localDraft = null,
  command = null,
  reconcileReply = { status: "error" },
} = {}) {
  const inputs = [
    "session-resolution-count",
    "session-resolution-duration",
    "session-resolution-mood",
    "session-resolution-tags",
    "session-resolution-notes",
  ].map((id) => new FakeElement(id));
  const root = new FakeElement("session-resolution");
  root.dataset.clientSessionId = "session-1";
  root.dataset.sessionStatus = status;
  root.querySelector = (selector) =>
    inputs.find((input) => `#${input.id}` === selector) || null;

  const pushes = [];
  const serverEventHandlers = new Map();
  const hook = {
    el: root,
    openSessionStore: async () => ({
      loadDraftByClientSessionId: async () => localDraft,
      loadLifecycleCommand: async () => command,
      markTraceReady: async () => {},
      deleteLifecycleCommand: async () => {},
      deleteDraft: async () => {},
    }),
    pushEvent(name, payload, callback) {
      pushes.push({ name, payload, callback });
      callback?.(reconcileReply);
    },
    handleEvent(name, handler) {
      serverEventHandlers.set(name, handler);
    },
    ...SessionRecoveryHook,
  };
  hook.mounted();

  return { hook, inputs, pushes, serverEventHandlers };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

test("running recovery replays only an exact completed local lifecycle command", async () => {
  const { hook, pushes } = mountedHook({
    status: "running",
    localDraft: draft(),
    command: {
      client_session_id: "session-1",
      kind: "mark_report_pending",
      payload: { client_session_id: "session-1" },
    },
  });

  await hook.recovery;

  assert.deepEqual(pushes.map(({ name, payload }) => ({ name, payload })), [
    {
      name: "reconcile_local_completion",
      payload: { client_session_id: "session-1" },
    },
  ]);
});

test("successful running reconciliation prefills the exact local draft", async () => {
  const { hook, inputs } = mountedHook({
    status: "running",
    localDraft: draft(),
    command: {
      client_session_id: "session-1",
      kind: "mark_report_pending",
      payload: { client_session_id: "session-1" },
    },
    reconcileReply: { status: "ok", lifecycle_status: "report_pending" },
  });

  await hook.recovery;

  assert.deepEqual(
    inputs.map(({ value }) => value),
    ["12", "88", "1", "great_energy,tired", "Recovered locally"],
  );
});

test("matching pending draft prefills report fields and preserves source identity fields", async () => {
  const { hook, inputs, pushes } = mountedHook({
    status: "report_pending",
    localDraft: draft(),
  });
  const events = [];
  for (const input of inputs) {
    input.addEventListener("input", () => events.push(`${input.id}:input`));
    input.addEventListener("change", () => events.push(`${input.id}:change`));
  }

  await hook.recovery;

  assert.deepEqual(
    inputs.map(({ value }) => value),
    ["12", "88", "1", "great_energy,tired", "Recovered locally"],
  );
  assert.equal(events.length, 10);
  assert.deepEqual(pushes, []);
});

test("missing or mismatched local recovery leaves the manual resolver untouched", async () => {
  for (const localDraft of [null, draft("other-session")]) {
    const { hook, inputs, pushes } = mountedHook({
      status: "report_pending",
      localDraft,
      command: {
        client_session_id: "other-session",
        kind: "mark_report_pending",
        payload: { client_session_id: "other-session" },
      },
    });

    await hook.recovery;

    assert.deepEqual(inputs.map(({ value }) => value), ["", "", "", "", ""]);
    assert.deepEqual(pushes, []);
  }
});

test("report acknowledgement marks trace ready before emitting and cleaning local recovery", async () => {
  const calls = [];
  const originalWindow = globalThis.window;
  const originalCustomEvent = globalThis.CustomEvent;
  globalThis.window = {
    dispatchEvent(event) {
      calls.push(event.type);
    },
  };
  globalThis.CustomEvent = class {
    constructor(type) {
      this.type = type;
    }
  };

  const { hook, serverEventHandlers } = mountedHook({
    status: "report_pending",
    localDraft: draft(),
  });
  await hook.recovery;
  hook.store = {
    async markTraceReady(clientSessionId, sessionId) {
      calls.push(`ready:${clientSessionId}:${sessionId}`);
    },
    async deleteLifecycleCommand(clientSessionId) {
      calls.push(`command:${clientSessionId}`);
    },
    async deleteDraft(clientSessionId) {
      calls.push(`draft:${clientSessionId}`);
    },
  };

  try {
    await serverEventHandlers.get("session_reported")({ session_id: 42 });
    assert.deepEqual(calls, [
      "ready:session-1:42",
      "burpee:trace-upload-ready",
      "command:session-1",
      "draft:session-1",
    ]);
  } finally {
    globalThis.window = originalWindow;
    globalThis.CustomEvent = originalCustomEvent;
  }
});
