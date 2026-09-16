import test from "node:test";
import assert from "node:assert/strict";
import HomePendingSession from "./home_pending_session.mjs";

function mount(loadDraft) {
  const label = { textContent: "In progress" };
  const action = { innerHTML: "", querySelector: () => null };
  const actionLabel = { textContent: "Resume workout" };
  const el = {
    dataset: { sessionId: "23", contentHash: "plan-hash" },
    querySelector(selector) {
      if (selector === "#home-session-state") return label;
      if (selector === "#home-resume-action-label") return actionLabel;
      throw new Error(`Unexpected selector ${selector}`);
    },
  };
  const hook = { ...HomePendingSession, el, openStore: async () => ({ loadDraft }) };
  HomePendingSession.mounted.call(hook);
  return { hook, label, actionLabel, action };
}

test("finished unsaved draft changes the truthful Home status and action", async () => {
  const { hook, label, actionLabel } = mount(async (identity) => {
    assert.deepEqual(identity, { sessionId: 23, contentHash: "plan-hash" });
    return { session_id: 23, content_hash: "plan-hash", note_post: "Done" };
  });
  await hook.pendingRead;
  assert.equal(label.textContent, "Session ready to log");
  assert.equal(actionLabel.textContent, "Review & save");
});

test("a workout without a completion draft stays in progress", async () => {
  const { hook, label, actionLabel } = mount(async () => null);
  await hook.pendingRead;
  assert.equal(label.textContent, "In progress");
  assert.equal(actionLabel.textContent, "Resume workout");
});

test("a destroyed Home hook ignores a late draft read", async () => {
  let finishRead;
  let reportStarted;
  const started = new Promise((resolve) => { reportStarted = resolve; });
  const { hook, label } = mount(() => new Promise((resolve) => {
    finishRead = resolve;
    reportStarted();
  }));
  await started;
  HomePendingSession.destroyed.call(hook);
  finishRead({ session_id: 23 });
  await hook.pendingRead;
  assert.equal(label.textContent, "In progress");
});
