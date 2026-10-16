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

function mount(choice, storage) {
  const attributes = { "aria-pressed": "false" };
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
  const hook = { ...HomeStartChoice, el, storage };
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
