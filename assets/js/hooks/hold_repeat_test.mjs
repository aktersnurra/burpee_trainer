import test from "node:test";
import assert from "node:assert/strict";
import { createHoldRepeat, HOLD_DELAY_MS, REPEAT_MS } from "./hold_repeat.mjs";

function stepper() {
	const listeners = new Map();
	const on = (owner) => ({
		addEventListener: (type, fn) => listeners.set(`${owner}:${type}`, fn),
		removeEventListener: (type) => listeners.delete(`${owner}:${type}`),
	});
	let now = 0;
	let timers = [];
	let nextId = 1;
	const schedule = (fn, ms, every) => {
		const id = nextId++;
		timers.push({ id, at: now + ms, fn, every });
		return id;
	};
	const clear = (id) => (timers = timers.filter((t) => t.id !== id));
	const win = {
		...on("win"),
		setTimeout: (fn, ms) => schedule(fn, ms, null),
		setInterval: (fn, ms) => schedule(fn, ms, ms),
		clearTimeout: clear,
		clearInterval: clear,
	};
	const advance = (ms) => {
		const end = now + ms;
		for (;;) {
			const due = timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at)[0];
			if (!due) break;
			now = due.at;
			if (due.every) due.at += due.every;
			else clear(due.id);
			due.fn();
		}
		now = end;
	};
	const button = {
		disabled: false,
		getAttribute: (name) => ({ "phx-value-field": "reps", "phx-value-dir": "up" })[name],
	};
	button.closest = () => button;
	const steps = [];
	const r = createHoldRepeat({ el: on("el"), win, onStep: (f, d) => steps.push(`${f}:${d}`) });
	r.mount();
	const fire = (key, e = {}) => listeners.get(key)?.({ target: button, button: 0, ...e });
	const click = () => {
		let stopped = false;
		fire("el:click", { stopPropagation: () => (stopped = true), preventDefault: () => {} });
		return stopped;
	};
	return { r, button, steps, fire, click, advance, listeners };
}

test("a press is the button's own click and adds nothing of the hook's", () => {
	const s = stepper();
	s.fire("el:pointerdown");
	s.advance(HOLD_DELAY_MS - 1);
	s.fire("win:pointerup");
	assert.equal(s.click(), false);
	s.advance(1_000);
	assert.deepEqual(s.steps, []);
});

test("a hold repeats the step until let go, and the click that ends it is swallowed", () => {
	const s = stepper();
	s.fire("el:pointerdown");
	s.advance(HOLD_DELAY_MS + 2 * REPEAT_MS);
	assert.deepEqual(s.steps, ["reps:up", "reps:up", "reps:up"]);
	s.fire("win:pointerup");
	assert.equal(s.click(), true);
	s.advance(1_000);
	assert.equal(s.steps.length, 3);
	// The next press starts afresh.
	assert.equal(s.click(), false);
});

test("a hold stops when the button is disabled at its limit, or the pointer leaves", () => {
	const s = stepper();
	s.fire("el:pointerdown");
	s.advance(HOLD_DELAY_MS);
	s.button.disabled = true;
	s.advance(1_000);
	assert.equal(s.steps.length, 1);

	const t = stepper();
	t.fire("el:pointerdown");
	t.advance(HOLD_DELAY_MS);
	t.fire("el:pointerleave");
	t.advance(1_000);
	assert.equal(t.steps.length, 1);
	t.r.destroy();
	assert.equal(t.listeners.size, 0);
});
