import test from "node:test";
import assert from "node:assert/strict";
import HomeStartChoice from "./home_start_choice.mjs";

function memoryStorage(entries = {}) {
  const values = new Map(Object.entries(entries));
  return {
    getItem: (key) => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value)),
    values,
  };
}

function mount(choice, storage, mediaDevices) {
  const attributes = {
    "aria-pressed": "false",
    "aria-label": choice === "camera" ? "Camera tracking" : "Warmup",
  };
  const listeners = {};
  const el = {
    dataset: { startChoice: choice },
    getAttribute: (name) => attributes[name],
    setAttribute: (name, value) => {
      attributes[name] = String(value);
    },
    addEventListener: (type, fn) => {
      listeners[type] = fn;
    },
    removeEventListener: (type) => {
      delete listeners[type];
    },
  };
  el.disabled = false;
  const hook = { ...HomeStartChoice, el, storage, mediaDevices };
  HomeStartChoice.mounted.call(hook);
  return { hook, attributes, click: () => listeners.click?.(), listeners };
}

test("each toggle shows this device's choice", () => {
  const storage = memoryStorage({ "burpee.start.camera": "1" });
  assert.equal(mount("camera", storage).attributes["aria-pressed"], "true");
  assert.equal(mount("warmup", storage).attributes["aria-pressed"], "true");
  assert.equal(mount("camera", memoryStorage()).attributes["aria-pressed"], "false");
});

test("a tap flips the choice and remembers it", () => {
  const storage = memoryStorage();
  const { attributes, click } = mount("warmup", storage);
  click();
  assert.equal(attributes["aria-pressed"], "false");
  assert.equal(storage.values.get("burpee.start.warmup"), "0");
  click();
  assert.equal(attributes["aria-pressed"], "true");
  assert.equal(storage.values.get("burpee.start.warmup"), "1");
});

test("leaving Home drops the listener", () => {
  const { hook, listeners } = mount("camera", memoryStorage());
  HomeStartChoice.destroyed.call(hook);
  assert.equal(listeners.click, undefined);
});

function cameras(...kinds) {
  const listeners = {};
  return {
    kinds,
    enumerateDevices: async function () {
      return this.kinds.map((kind) => ({ kind }));
    },
    addEventListener: (type, fn) => {
      listeners[type] = fn;
    },
    removeEventListener: (type) => {
      delete listeners[type];
    },
    listeners,
  };
}

test("a device without a camera cannot choose it", async () => {
  const storage = memoryStorage({ "burpee.start.camera": "1" });
  const { hook, attributes } = mount("camera", storage, cameras("audioinput"));
  await hook.cameraChecked;
  assert.equal(hook.el.disabled, true);
  assert.equal(attributes["aria-pressed"], "false");
  assert.equal(attributes["aria-label"], "No camera on this device");
  assert.equal(attributes.title, "No camera on this device");
  // The remembered choice is this device's, and is left for when a camera appears.
  assert.equal(storage.values.get("burpee.start.camera"), "1");
});

test("plugging in a camera brings the choice back", async () => {
  const storage = memoryStorage({ "burpee.start.camera": "1" });
  const media = cameras("audioinput");
  const { hook, attributes } = mount("camera", storage, media);
  await hook.cameraChecked;
  media.kinds = ["videoinput"];
  media.listeners.devicechange();
  await hook.cameraChecked;
  assert.equal(hook.el.disabled, false);
  assert.equal(attributes["aria-pressed"], "true");
  assert.equal(attributes["aria-label"], "Camera tracking");

  HomeStartChoice.destroyed.call(hook);
  assert.equal(media.listeners.devicechange, undefined);
});

test("a browser that cannot say leaves the camera choice alone", async () => {
  const storage = memoryStorage({ "burpee.start.camera": "1" });
  const { hook, attributes } = mount("camera", storage, {});
  await hook.cameraChecked;
  assert.equal(hook.el.disabled, false);
  assert.equal(attributes["aria-pressed"], "true");
});

test("the warmup never asks about cameras", async () => {
  const { hook } = mount("warmup", memoryStorage(), cameras());
  assert.equal(hook.cameraChecked, undefined);
  assert.equal(hook.el.disabled, false);
});
