import test from "node:test";
import assert from "node:assert/strict";
import PoseTracker from "./pose_tracker.js";

globalThis.CustomEvent ??= class {
  constructor(type, init = {}) {
    this.type = type;
    this.detail = init.detail;
  }
};

function element() {
  const listeners = new Map();
  return {
    isConnected: true,
    addEventListener(type, fn) {
      listeners.set(type, [...(listeners.get(type) || []), fn]);
    },
    removeEventListener(type, fn) {
      listeners.set(type, (listeners.get(type) || []).filter((other) => other !== fn));
    },
    dispatchEvent(event) {
      for (const fn of listeners.get(event.type) || []) fn(event);
    },
  };
}

// The session may ask for the camera before the tracker's code has loaded.
function mountWithSlowLoad(el) {
  const received = [];
  let finishLoad;
  const loaded = new Promise((resolve) => {
    finishLoad = resolve;
  });
  const hook = {
    ...PoseTracker,
    el,
    loadImpl: () =>
      loaded.then(() => ({
        createPoseTracker: (owner) => ({
          async mounted() {
            for (const type of ["pose-tracker:start", "pose-tracker:stop"]) {
              owner.el.addEventListener(type, () => received.push(type));
            }
          },
        }),
      })),
  };
  const mounting = hook.mounted();
  return { hook, received, finish: () => finishLoad() || mounting };
}

test("a start sent while the tracker loads is not lost", async () => {
  const el = element();
  const { received, finish } = mountWithSlowLoad(el);
  el.dispatchEvent(new CustomEvent("pose-tracker:start"));
  await finish();
  assert.deepEqual(received, ["pose-tracker:start"]);

  el.dispatchEvent(new CustomEvent("pose-tracker:start"));
  assert.deepEqual(received, ["pose-tracker:start", "pose-tracker:start"]);
});

test("a stop after an early start cancels it", async () => {
  const el = element();
  const { received, finish } = mountWithSlowLoad(el);
  el.dispatchEvent(new CustomEvent("pose-tracker:start"));
  el.dispatchEvent(new CustomEvent("pose-tracker:stop"));
  await finish();
  assert.deepEqual(received, []);
});

test("nothing is replayed when nothing was asked", async () => {
  const el = element();
  const { received, finish } = mountWithSlowLoad(el);
  await finish();
  assert.deepEqual(received, []);
});
