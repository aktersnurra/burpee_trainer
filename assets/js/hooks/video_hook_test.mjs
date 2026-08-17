import assert from "node:assert/strict";
import test from "node:test";

import VideoHook from "./video_hook.js";

function fakeElement() {
  const listeners = new Map();

  return {
    listeners,
    hidden: true,
    disabled: false,
    textContent: "",
    href: "",
    addEventListener(type, callback) {
      listeners.set(type, callback);
    },
    emit(type) {
      listeners.get(type)?.();
    },
  };
}

function mountedHook() {
  const video = fakeElement();
  video.pauseCalls = 0;
  video.playCalls = 0;
  video.pause = () => video.pauseCalls++;
  video.play = () => {
    video.playCalls++;
    return Promise.resolve();
  };

  const controls = {
    "video-start-workout": fakeElement(),
    "video-lifecycle-status": fakeElement(),
    "video-lifecycle-error": fakeElement(),
    "video-resolve-session": fakeElement(),
    "video-report-retry": fakeElement(),
  };
  const previousDocument = globalThis.document;
  globalThis.document = { getElementById: (id) => controls[id] || null };

  const calls = [];
  const hook = {
    el: video,
    pushEvent(name, payload, callback) {
      calls.push({ name, payload, callback });
    },
    ...VideoHook,
  };
  hook.mounted();

  return {
    video,
    controls,
    calls,
    hook,
    restoreDocument: () => {
      globalThis.document = previousDocument;
    },
  };
}

test("video begins only after durable begin succeeds and blocks native play before then", async (t) => {
  const { video, controls, calls, restoreDocument } = mountedHook();
  t.after(restoreDocument);

  video.emit("play");
  assert.equal(video.pauseCalls, 1);

  controls["video-start-workout"].emit("click");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "begin_video_session");
  assert.match(calls[0].payload.client_session_id, /^[0-9a-f-]{36}$/i);
  assert.equal(video.playCalls, 0);

  calls[0].callback({ status: "ok" });
  await Promise.resolve();
  assert.equal(video.playCalls, 1);
  assert.equal(controls["video-start-workout"].disabled, true);
});

test("video end waits for report-pending success and retains retry after a failure", (t) => {
  const { video, controls, calls, restoreDocument } = mountedHook();
  t.after(restoreDocument);

  controls["video-start-workout"].emit("click");
  calls[0].callback({ status: "ok" });
  video.emit("ended");

  assert.equal(calls[1].name, "mark_video_report_pending");
  calls[1].callback({ status: "error", message: "Try again." });
  assert.equal(controls["video-report-retry"].hidden, false);

  controls["video-report-retry"].emit("click");
  assert.equal(calls[2].name, "mark_video_report_pending");
  assert.equal(
    calls[2].payload.client_session_id,
    calls[0].payload.client_session_id,
  );
});
