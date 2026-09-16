import test from "node:test";
import assert from "node:assert/strict";
import SessionCompleted from "./session_completed.mjs";

function mount(finalizeServerCompletion) {
  const calls = { navigated: [], events: [] };
  const el = {
    dataset: {
      sessionId: "23",
      contentHash: "plan-hash",
      clientSessionId: "client-1",
      redirectTo: "/",
    },
  };
  const hook = {
    ...SessionCompleted,
    el,
    openStore: async () => ({ finalizeServerCompletion }),
    navigate: (to) => calls.navigated.push(to),
    announce: (name) => calls.events.push(name),
  };
  SessionCompleted.mounted.call(hook);
  return { hook, calls };
}

test("an already-saved session finalizes local evidence and returns home", async () => {
  const { hook, calls } = mount(async (...identity) => {
    assert.deepEqual(identity, [23, "plan-hash", "client-1"]);
    return { traceReady: true };
  });
  await hook.finalized;
  assert.deepEqual(calls.events, ["burpee:trace-upload-ready"]);
  assert.deepEqual(calls.navigated, ["/"]);
});

test("without pending trace chunks no upload is announced", async () => {
  const { hook, calls } = mount(async () => ({ traceReady: false }));
  await hook.finalized;
  assert.deepEqual(calls.events, []);
  assert.deepEqual(calls.navigated, ["/"]);
});

test("unavailable local storage still returns home and keeps evidence", async () => {
  const { hook, calls } = mount(async () => {
    throw new Error("blocked");
  });
  await hook.finalized;
  assert.deepEqual(calls.events, []);
  assert.deepEqual(calls.navigated, ["/"]);
});

test("a destroyed hook does not navigate late", async () => {
  let finish;
  let reportStarted;
  const started = new Promise((resolve) => (reportStarted = resolve));
  const { hook, calls } = mount(
    () =>
      new Promise((resolve) => {
        finish = resolve;
        reportStarted();
      }),
  );
  await started;
  SessionCompleted.destroyed.call(hook);
  finish({ traceReady: true });
  await hook.finalized;
  assert.deepEqual(calls.navigated, []);
});
