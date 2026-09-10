import test from "node:test";
import assert from "node:assert/strict";
import HomeAdjustment from "./home_adjustment.mjs";

test("sizes the actual editable control and cleans up", () => {
  const listeners = new Map();
  const el = {
    style: {},
    scrollHeight: 84,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name, fn) => {
      assert.equal(listeners.get(name), fn);
      listeners.delete(name);
    },
  };
  const hook = { el };
  HomeAdjustment.mounted.call(hook);
  assert.equal(el.style.height, "84px");
  el.scrollHeight = 126;
  listeners.get("input")();
  assert.equal(el.style.height, "126px");
  HomeAdjustment.destroyed.call(hook);
  assert.equal(listeners.size, 0);
});

test("resets height before measuring so deleted text can shrink", () => {
  let input;
  let contentHeight = 126;
  const el = {
    style: {},
    get scrollHeight() {
      assert.equal(this.style.height, "auto");
      return contentHeight;
    },
    addEventListener: (_name, fn) => {
      input = fn;
    },
    removeEventListener: () => {},
  };
  const hook = { el };
  HomeAdjustment.mounted.call(hook);
  contentHeight = 42;
  input();
  assert.equal(el.style.height, "42px");
  HomeAdjustment.destroyed.call(hook);
});
