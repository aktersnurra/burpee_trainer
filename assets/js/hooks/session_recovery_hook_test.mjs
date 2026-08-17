import assert from "node:assert/strict";
import test from "node:test";

import SessionRecoveryHook from "./session_recovery_hook.js";

class FakeElement {
  constructor(id) {
    this.id = id;
    this.value = "";
    this.name = "";
    this.dataset = {};
    this.disabled = false;
    this.listeners = new Map();
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  dispatchEvent(event) {
    for (const listener of this.listeners.get(event.type) || [])
      listener(event);
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

function deferred() {
  let resolve;
  const promise = new Promise((next) => {
    resolve = next;
  });
  return { promise, resolve };
}

function mountedHook({
  status = "report_pending",
  localDraft = null,
  command = null,
  reconcileReply = { status: "error" },
  reportReply = {
    status: "ok",
    session_id: 42,
    client_session_id: "session-1",
    redirect_to: "/stats",
  },
  openSessionStore,
} = {}) {
  const fieldNames = [
    "burpee_count_actual",
    "duration_sec_actual",
    "mood",
    "tags",
    "note_post",
  ];
  const inputs = [
    "session-resolution-count",
    "session-resolution-duration",
    "session-resolution-mood",
    "session-resolution-tags",
    "session-resolution-notes",
  ].map((id, index) => {
    const input = new FakeElement(id);
    input.name = `workout_session[${fieldNames[index]}]`;
    return input;
  });
  const form = new FakeElement("session-resolution-form");
  form.elements = inputs;
  const root = new FakeElement("session-resolution");
  root.dataset.clientSessionId = "session-1";
  root.dataset.sessionStatus = status;
  root.querySelector = (selector) => {
    if (selector === "#session-resolution-form") return form;
    return inputs.find((input) => `#${input.id}` === selector) || null;
  };

  const calls = [];
  const pushes = [];
  const navigations = [];
  const store = {
    loadDraftByClientSessionId: async () => localDraft,
    loadLifecycleCommand: async () => command,
    markTraceReady: async (clientSessionId, sessionId) =>
      calls.push(`ready:${clientSessionId}:${sessionId}`),
    deleteLifecycleCommand: async (clientSessionId) =>
      calls.push(`command:${clientSessionId}`),
    deleteDraft: async (clientSessionId) =>
      calls.push(`draft:${clientSessionId}`),
  };
  const hook = {
    ...SessionRecoveryHook,
    el: root,
    openSessionStore: openSessionStore || (async () => store),
    pushEvent(name, payload, callback) {
      pushes.push({ name, payload, callback });
      callback?.(name === "report" ? reportReply : reconcileReply);
    },
    navigateTo(target) {
      navigations.push(target);
    },
  };
  hook.mounted();

  return { hook, inputs, pushes, calls, navigations, store };
}

function withTraceReadyWindow(t, calls) {
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
  t.after(() => {
    globalThis.window = originalWindow;
    globalThis.CustomEvent = originalCustomEvent;
  });
}

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

  assert.deepEqual(
    pushes.map(({ name, payload }) => ({ name, payload })),
    [
      {
        name: "reconcile_local_completion",
        payload: { client_session_id: "session-1" },
      },
    ],
  );
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

test("delayed recovery does not overwrite a field manually typed before storage resolves", async () => {
  const opened = deferred();
  const { hook, inputs } = mountedHook({
    localDraft: draft(),
    openSessionStore: () => opened.promise,
  });

  inputs[0].value = "31";
  inputs[0].dispatchEvent(new Event("input", { bubbles: true }));
  opened.resolve({
    loadDraftByClientSessionId: async () => draft(),
    loadLifecycleCommand: async () => null,
  });

  await hook.recovery;

  assert.deepEqual(
    inputs.map(({ value }) => value),
    ["31", "88", "1", "great_energy,tired", "Recovered locally"],
  );
});

test("report reply waits for storage before trace readiness, cleanup, and navigation", async (t) => {
  const opened = deferred();
  const { hook, pushes, calls, navigations } = mountedHook({
    localDraft: null,
    openSessionStore: () => opened.promise,
  });
  withTraceReadyWindow(t, calls);

  const submission = hook.submitReport();
  assert.deepEqual(pushes[0], {
    name: "report",
    payload: {
      workout_session: {
        burpee_count_actual: "",
        duration_sec_actual: "",
        mood: "",
        tags: "",
        note_post: "",
      },
    },
    callback: pushes[0].callback,
  });
  assert.deepEqual(calls, []);
  assert.deepEqual(navigations, []);

  opened.resolve({
    loadDraftByClientSessionId: async () => null,
    loadLifecycleCommand: async () => null,
    async markTraceReady(clientSessionId, sessionId) {
      calls.push(`ready:${clientSessionId}:${sessionId}`);
    },
    async deleteLifecycleCommand(clientSessionId) {
      calls.push(`command:${clientSessionId}`);
    },
    async deleteDraft(clientSessionId) {
      calls.push(`draft:${clientSessionId}`);
    },
  });
  await submission;

  assert.deepEqual(calls, [
    "ready:session-1:42",
    "burpee:trace-upload-ready",
    "command:session-1",
    "draft:session-1",
  ]);
  assert.deepEqual(navigations, ["/stats"]);
});

test("a successful report still navigates when IndexedDB is unavailable", async () => {
  const { hook, calls, navigations } = mountedHook({
    openSessionStore: async () => {
      throw new Error("IndexedDB is unavailable");
    },
  });

  await hook.recovery;
  await hook.submitReport();

  assert.deepEqual(calls, []);
  assert.deepEqual(navigations, ["/stats"]);
});

test("failed trace acknowledgement retains recovery data for a report replay", async (t) => {
  let attempts = 0;
  const { hook, store, calls, navigations } = mountedHook();
  withTraceReadyWindow(t, calls);
  store.markTraceReady = async () => {
    attempts += 1;
    if (attempts === 1) throw new Error("write failed");
    calls.push("ready:session-1:42");
  };

  await hook.recovery;
  await hook.submitReport();
  assert.deepEqual(calls, []);
  assert.deepEqual(navigations, []);

  await hook.submitReport();
  assert.deepEqual(calls, [
    "ready:session-1:42",
    "burpee:trace-upload-ready",
    "command:session-1",
    "draft:session-1",
  ]);
  assert.deepEqual(navigations, ["/stats"]);
});
