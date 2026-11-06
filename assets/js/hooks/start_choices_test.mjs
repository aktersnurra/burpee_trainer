import test from "node:test";
import assert from "node:assert/strict";
import { readStartChoices, writeStartChoice } from "./start_choices.mjs";

// A document's cookie jar: assigning sets one cookie, reading gives "name=value; ...".
function cookieJar(entries = {}) {
  const values = new Map(Object.entries(entries));
  const written = [];
  return {
    get cookie() {
      return [...values].map(([name, value]) => `${name}=${value}`).join("; ");
    },
    set cookie(line) {
      written.push(line);
      const [name, value] = line.split(";")[0].split("=");
      values.set(name, value);
    },
    values,
    written,
  };
}

const refusing = {
  get cookie() {
    throw new Error("blocked");
  },
  set cookie(_line) {
    throw new Error("blocked");
  },
};

test("a device that never chose starts without the camera and with the warmup", () => {
  assert.deepEqual(readStartChoices(cookieJar()), { camera: false, warmup: true });
});

test("a choice is remembered where the server reads it on every page", () => {
  const jar = cookieJar({ other: "x" });
  writeStartChoice("camera", true, jar);
  writeStartChoice("warmup", false, jar);
  assert.deepEqual(readStartChoices(jar), { camera: true, warmup: false });
  assert.equal(jar.values.get("burpee_start_camera"), "1");
  assert.equal(jar.values.get("burpee_start_warmup"), "0");
  for (const line of jar.written) {
    assert.match(line, /; path=\/;/);
    assert.match(line, /; max-age=\d+;/);
  }
});

test("a value the app did not write falls back to the default", () => {
  const jar = cookieJar({ burpee_start_camera: "yes", burpee_start_warmup: "" });
  assert.deepEqual(readStartChoices(jar), { camera: false, warmup: true });
});

test("cookies that are refused or missing never stop a workout", () => {
  assert.deepEqual(readStartChoices(refusing), { camera: false, warmup: true });
  assert.deepEqual(readStartChoices(undefined), { camera: false, warmup: true });
  assert.doesNotThrow(() => writeStartChoice("camera", true, refusing));
  assert.doesNotThrow(() => writeStartChoice("camera", true, undefined));
});

test("only the two choices are stored", () => {
  const jar = cookieJar();
  writeStartChoice("audio", true, jar);
  assert.equal(jar.values.size, 0);
});
