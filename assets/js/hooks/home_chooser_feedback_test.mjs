import test from "node:test";
import assert from "node:assert/strict";
import { registerHomeChooserFeedback } from "./home_chooser_feedback.mjs";

function fixture() {
  const events = new Map();
  const calls = [];
  const alert = {
    focus: (options) => calls.push(["focus", options]),
    scrollIntoView: (options) => calls.push(["scroll", options]),
  };
  let current = alert;
  const root = { querySelector(selector) {
    assert.equal(selector, '#home-page[data-home-state="choose"] #home-alternatives-panel:not([hidden]):not([inert]) #home-chooser-error[role="alert"]');
    return current;
  }};
  const target = { addEventListener(name, callback) {
    assert.equal(name, "phx:home_chooser_rejected");
    assert.equal(events.has(name), false, "one registration only");
    events.set(name, callback);
  }};
  return { target, root, calls, emit: () => events.get("phx:home_chooser_rejected")(), absent: () => { current = null; } };
}

test("server rejection focuses then scrolls on first AND identical repeat", () => {
  const f = fixture();
  registerHomeChooserFeedback(f.target, f.root);
  f.emit();
  f.emit();
  assert.deepEqual(f.calls, [
    ["focus", { preventScroll: true }],
    ["scroll", { block: "nearest", behavior: "instant" }],
    ["focus", { preventScroll: true }],
    ["scroll", { block: "nearest", behavior: "instant" }],
  ]);
});

test("absent hidden inert or stale non-Choose alert is a no-op", () => {
  const f = fixture();
  f.absent();
  registerHomeChooserFeedback(f.target, f.root);
  assert.doesNotThrow(f.emit);
  assert.deepEqual(f.calls, []);
});

test("registration is idempotent and supports default browser callers", () => {
  const f = fixture();
  globalThis.window = f.target;
  globalThis.document = f.root;
  try {
    registerHomeChooserFeedback();
    registerHomeChooserFeedback();
    f.emit();
    assert.equal(f.calls.length, 2);
  } finally {
    delete globalThis.window;
    delete globalThis.document;
  }
});
