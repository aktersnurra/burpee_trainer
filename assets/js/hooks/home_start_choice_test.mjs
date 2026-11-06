import test from "node:test";
import assert from "node:assert/strict";
import HomeStartChoice from "./home_start_choice.mjs";
import { readStartChoices } from "./start_choices.mjs";

// The device's cookies, as `document.cookie` reads and sets them.
function cookieJar(entries = {}) {
  const values = new Map(Object.entries(entries));
  return {
    get cookie() {
      return [...values].map(([name, value]) => `${name}=${value}`).join("; ");
    },
    set cookie(line) {
      const [name, value] = line.split(";")[0].split("=");
      values.set(name, value);
    },
    values,
  };
}

// Mounts the hook on a toggle the server rendered from the same cookies.
function mount(choice, storage, mediaDevices) {
  const remembered = readStartChoices(storage)[choice];
  const attributes = {
    "aria-pressed": String(remembered),
    "aria-label": choice === "camera" ? "Camera tracking" : "Warmup",
  };
  const pressedHistory = [attributes["aria-pressed"]];
  const pushed = [];
  const listeners = {};
  const el = {
    dataset: { startChoice: choice },
    getAttribute: (name) => attributes[name],
    setAttribute: (name, value) => {
      attributes[name] = String(value);
      if (name === "aria-pressed" && pressedHistory.at(-1) !== String(value)) {
        pressedHistory.push(String(value));
      }
    },
    addEventListener: (type, fn) => {
      listeners[type] = fn;
    },
    removeEventListener: (type) => {
      delete listeners[type];
    },
  };
  el.disabled = false;
  const hook = {
    ...HomeStartChoice,
    el,
    storage,
    mediaDevices,
    pushEvent: (event, payload) => pushed.push([event, payload]),
  };
  HomeStartChoice.mounted.call(hook);
  return { hook, attributes, pressedHistory, pushed, click: () => listeners.click?.(), listeners };
}

test("mounting never changes how the server rendered the toggle", async () => {
  for (const [choice, entries] of [
    ["camera", { burpee_start_camera: "1" }],
    ["camera", {}],
    ["warmup", { burpee_start_warmup: "0" }],
    ["warmup", {}],
  ]) {
    const { hook, pressedHistory } = mount(choice, cookieJar(entries), cameras("videoinput"));
    await hook.cameraChecked;
    assert.equal(pressedHistory.length, 1, `${choice} ${JSON.stringify(entries)}`);
  }
});

test("a tap flips the choice, remembers it and tells Home", () => {
  const storage = cookieJar();
  const { attributes, pushed, click } = mount("warmup", storage);
  click();
  assert.equal(attributes["aria-pressed"], "false");
  assert.equal(storage.values.get("burpee_start_warmup"), "0");
  click();
  assert.equal(attributes["aria-pressed"], "true");
  assert.equal(storage.values.get("burpee_start_warmup"), "1");
  assert.deepEqual(pushed, [
    ["start_choice", { choice: "warmup", pressed: false }],
    ["start_choice", { choice: "warmup", pressed: true }],
  ]);
});

test("leaving Home drops the listener", () => {
  const { hook, listeners } = mount("camera", cookieJar());
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
  const storage = cookieJar({ burpee_start_camera: "1" });
  const { hook, attributes } = mount("camera", storage, cameras("audioinput"));
  await hook.cameraChecked;
  assert.equal(hook.el.disabled, true);
  assert.equal(attributes["aria-pressed"], "false");
  assert.equal(attributes["aria-label"], "No camera on this device");
  assert.equal(attributes.title, "No camera on this device");
  // The remembered choice is this device's, and is left for when a camera appears.
  assert.equal(storage.values.get("burpee_start_camera"), "1");
});

test("plugging in a camera brings the choice back", async () => {
  const storage = cookieJar({ burpee_start_camera: "1" });
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
  const storage = cookieJar({ burpee_start_camera: "1" });
  const { hook, attributes } = mount("camera", storage, {});
  await hook.cameraChecked;
  assert.equal(hook.el.disabled, false);
  assert.equal(attributes["aria-pressed"], "true");
});

test("the warmup never asks about cameras", async () => {
  const { hook } = mount("warmup", cookieJar(), cameras());
  assert.equal(hook.cameraChecked, undefined);
  assert.equal(hook.el.disabled, false);
});
