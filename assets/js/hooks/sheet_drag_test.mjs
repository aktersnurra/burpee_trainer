import test from "node:test";
import assert from "node:assert/strict";
import { createSheetDrag, dragOutcome, CLOSE_PX_PER_MS } from "./sheet_drag.mjs";

test("a drag closes the sheet when pulled a quarter of its height or flicked, else it settles back", () => {
	assert.equal(dragOutcome({ dy: 200, ms: 600, height: 700 }), "close");
	assert.equal(dragOutcome({ dy: 60, ms: 600, height: 700 }), "stay");
	assert.equal(dragOutcome({ dy: 60, ms: 60 / CLOSE_PX_PER_MS - 1, height: 700 }), "close");
	assert.equal(dragOutcome({ dy: -40, ms: 50, height: 700 }), "stay");
});

function fixture({ phone = true, scrollTop = 0 } = {}) {
	const handlers = new Map();
	const clicks = [];
	const el = {
		scrollTop,
		offsetHeight: 700,
		dataset: { close: "#close", backdrop: "#scrim" },
		style: {},
		addEventListener: (name, fn, opts) => handlers.set(name, { fn, opts }),
		removeEventListener: (name) => handlers.delete(name),
	};
	const scrim = { style: {} };
	const doc = {
		querySelector: (s) => (s === "#close" ? { click: () => clicks.push(s) } : s === "#scrim" ? scrim : null),
	};
	const win = { matchMedia: () => ({ matches: phone }) };
	let t = 0;
	const drag = createSheetDrag({ el, win, doc, now: () => t });
	drag.mount();
	const fire = (name, y, prevented = []) =>
		handlers.get(name).fn({
			touches: [{ clientY: y }],
			changedTouches: [{ clientY: y }],
			preventDefault: () => prevented.push(name),
		});
	return { el, scrim, clicks, handlers, fire, drag, tick: (ms) => (t += ms) };
}

test("on a phone the sheet follows the finger down and closes through its own close button", () => {
	const f = fixture();
	assert.equal(f.handlers.get("touchmove").opts.passive, false);
	const prevented = [];
	f.fire("touchstart", 100);
	f.fire("touchmove", 160, prevented);
	f.fire("touchmove", 400, prevented);
	assert.equal(f.el.style.transform, "translateY(300px)");
	assert.equal(f.el.style.transition, "none");
	assert.deepEqual(prevented, ["touchmove", "touchmove"]);
	f.tick(500);
	f.fire("touchend", 400);
	assert.deepEqual(f.clicks, ["#close"]);
	// The stylesheet takes it from there, transitioning from where the finger left it.
	assert.equal(f.el.style.transform, "");
	assert.equal(f.el.style.transition, "");
	assert.equal(f.scrim.style.opacity, "");
});

test("a short slow pull settles back; a scroll up, a scrolled list and a wide screen are left alone", () => {
	const short = fixture();
	short.fire("touchstart", 100);
	short.fire("touchmove", 140);
	short.tick(800);
	short.fire("touchend", 140);
	assert.deepEqual(short.clicks, []);
	assert.equal(short.el.style.transform, "");

	for (const f of [fixture({ scrollTop: 40 }), fixture({ phone: false })]) {
		f.fire("touchstart", 100);
		f.fire("touchmove", 400);
		f.fire("touchend", 400);
		assert.equal(f.el.style.transform, undefined);
		assert.deepEqual(f.clicks, []);
	}

	const up = fixture();
	const prevented = [];
	up.fire("touchstart", 300);
	up.fire("touchmove", 250, prevented);
	up.fire("touchmove", 400, prevented);
	assert.deepEqual(prevented, []);
	assert.equal(up.el.style.transform, undefined);
});
