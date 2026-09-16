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

test("the action reflects typed and cleared instructions before the server responds", () => {
  const listeners = new Map();
  const attributes = {};
  const action = {
    setAttribute(name, value) { attributes[name] = value; },
  };
  const form = {
    dataset: {},
    querySelector(selector) {
      assert.equal(selector, "#home-action");
      return action;
    },
  };
  const el = {
    value: "",
    style: {},
    scrollHeight: 32,
    closest(selector) {
      assert.equal(selector, "form");
      return form;
    },
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name),
  };
  const hook = { el };
  HomeAdjustment.mounted.call(hook);
  el.value = "foo";
  listeners.get("input")();
  assert.equal(form.dataset.hasInstruction, "true");
  assert.equal(attributes["aria-label"], "Update");
  assert.equal(attributes.title, "Update");
  el.value = "  ";
  listeners.get("input")();
  assert.equal(form.dataset.hasInstruction, "false");
  assert.equal(attributes["aria-label"], "Start");
  HomeAdjustment.destroyed.call(hook);
  assert.equal(listeners.size, 0);
});

test("clears hook-owned text when the server selects another workout", () => {
  const listeners = new Map();
  const action = { attributes: {}, setAttribute(name, value) { this.attributes[name] = value; } };
  const form = {
    dataset: {},
    querySelector: () => action,
  };
  const el = {
    value: "",
    style: {},
    scrollHeight: 32,
    closest: () => form,
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: (name) => listeners.delete(name),
  };
  let reset;
  const hook = {
    el,
    handleEvent(name, callback) {
      assert.equal(name, "home_adjustment_reset");
      reset = callback;
    },
  };

  HomeAdjustment.mounted.call(hook);
  el.value = "Old instruction";
  listeners.get("input")();
  assert.equal(action.attributes["aria-label"], "Update");

  assert.equal(typeof reset, "function");
  reset();
  assert.equal(el.value, "");
  assert.equal(form.dataset.hasInstruction, "false");
  assert.equal(action.attributes["aria-label"], "Start");
  HomeAdjustment.destroyed.call(hook);
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
