import test from "node:test";
import assert from "node:assert/strict";
import SessionCompleted from "./session_completed.mjs";

function mount(finalizeServerCompletion) {
  const calls = { navigated: [], events: [], timers: new Map() };
  const el = {
    textContent: "",
    addEventListener() {},
    removeEventListener() {},
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
    scheduleRetry: (callback) => { calls.timers.set(1, callback); return 1; },
    cancelRetry: (id) => calls.timers.delete(id),
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

test("failed local finalization stays visible and retries before returning home", async () => {
  let attempts = 0;
  const { hook, calls } = mount(async () => {
    if (++attempts === 1) throw new Error("blocked");
    return { traceReady: true };
  });
  await hook.finalized;
  assert.deepEqual(calls.events, []);
  assert.deepEqual(calls.navigated, []);
  assert.match(hook.el.textContent, /retry/i);
  assert.equal(calls.timers.size, 1);
  await calls.timers.get(1)();
  assert.deepEqual(calls.events, ["burpee:trace-upload-ready"]);
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
