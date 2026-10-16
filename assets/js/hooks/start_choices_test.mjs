import test from "node:test";
import assert from "node:assert/strict";
import { readStartChoices, writeStartChoice } from "./start_choices.mjs";

function memoryStorage(entries = {}) {
  const values = new Map(Object.entries(entries));
  return {
    getItem: (key) => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value)),
    values,
  };
}

const throwing = {
  getItem() {
    throw new Error("blocked");
  },
  setItem() {
    throw new Error("blocked");
  },
};

test("a device that never chose starts without the camera and with the warmup", () => {
  assert.deepEqual(readStartChoices(memoryStorage()), { camera: false, warmup: true });
});

test("a choice is remembered", () => {
  const storage = memoryStorage();
  writeStartChoice("camera", true, storage);
  writeStartChoice("warmup", false, storage);
  assert.deepEqual(readStartChoices(storage), { camera: true, warmup: false });
  assert.equal(storage.values.get("burpee.start.camera"), "1");
  assert.equal(storage.values.get("burpee.start.warmup"), "0");
});

test("a value the app did not write falls back to the default", () => {
  const storage = memoryStorage({ "burpee.start.camera": "yes", "burpee.start.warmup": "" });
  assert.deepEqual(readStartChoices(storage), { camera: false, warmup: true });
});

test("storage that refuses or is missing never stops a workout", () => {
  assert.deepEqual(readStartChoices(throwing), { camera: false, warmup: true });
  assert.deepEqual(readStartChoices(undefined), { camera: false, warmup: true });
  assert.doesNotThrow(() => writeStartChoice("camera", true, throwing));
  assert.doesNotThrow(() => writeStartChoice("camera", true, undefined));
});

test("only the two choices are stored", () => {
  const storage = memoryStorage();
  writeStartChoice("audio", true, storage);
  assert.equal(storage.values.size, 0);
});
