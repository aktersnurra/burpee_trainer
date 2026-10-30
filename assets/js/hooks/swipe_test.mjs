import test from "node:test";
import assert from "node:assert/strict";
import { atPageBottom, classifySwipe, createSwipeTracker } from "./swipe.mjs";
import { gestureEvent } from "./home_gestures.mjs";
import { stepDirection } from "./swipe_value.mjs";

test("a clear, quick stroke is a swipe in its main direction", () => {
	assert.equal(classifySwipe({ dx: 120, dy: 10, ms: 200 }), "right");
	assert.equal(classifySwipe({ dx: -120, dy: -20, ms: 200 }), "left");
	assert.equal(classifySwipe({ dx: 10, dy: -120, ms: 200 }), "up");
	assert.equal(classifySwipe({ dx: -10, dy: 120, ms: 200 }), "down");
});

test("taps, drifts, diagonals and slow drags are not swipes", () => {
	assert.equal(classifySwipe({ dx: 4, dy: 3, ms: 80 }), null);
	assert.equal(classifySwipe({ dx: 40, dy: 0, ms: 100 }), null);
	assert.equal(classifySwipe({ dx: 100, dy: 90, ms: 200 }), null);
	assert.equal(classifySwipe({ dx: 200, dy: 0, ms: 2_000 }), null);
});

test("the page is at its bottom when nothing is left to scroll", () => {
	assert.equal(atPageBottom({ scrollTop: 0, innerHeight: 800, scrollHeight: 800 }), true);
	assert.equal(atPageBottom({ scrollTop: 0, innerHeight: 800, scrollHeight: 1200 }), false);
	assert.equal(atPageBottom({ scrollTop: 400, innerHeight: 800, scrollHeight: 1200 }), true);
});

function tracker({ scrollHeight = 800, ignore = null } = {}) {
	const listeners = new Map();
	const swipes = [];
	let time = 1_000;
	const el = {
		addEventListener: (name, fn) => listeners.set(name, fn),
		removeEventListener: (name) => listeners.delete(name),
	};
	const doc = { scrollingElement: { scrollTop: 0, scrollHeight }, documentElement: {} };
	const t = createSwipeTracker({
		el,
		win: { innerHeight: 800 },
		doc,
		ignore,
		now: () => time,
		onSwipe: (direction) => swipes.push(direction),
	});
	t.mount();
	const touch = (x, y) => ({ clientX: x, clientY: y });
	return {
		swipes,
		listeners,
		t,
		stroke(from, to, { touches = 1, target = {} } = {}) {
			listeners.get("touchstart")({
				touches: Array.from({ length: touches }, () => touch(...from)),
				target,
			});
			time += 150;
			listeners.get("touchend")({ changedTouches: [touch(...to)] });
		},
	};
}

test("the tracker reports a swipe when the finger lifts", () => {
	const f = tracker();
	f.stroke([50, 400], [250, 410]);
	f.stroke([300, 400], [100, 395]);
	assert.deepEqual(f.swipes, ["right", "left"]);
});

test("an upward stroke is a scroll while the page can still scroll down", () => {
	const scrolling = tracker({ scrollHeight: 1_600 });
	scrolling.stroke([200, 600], [205, 300]);
	assert.deepEqual(scrolling.swipes, []);

	const fits = tracker({ scrollHeight: 800 });
	fits.stroke([200, 600], [205, 300]);
	assert.deepEqual(fits.swipes, ["up"]);
});

test("two fingers and strokes that start in an ignored element are left alone", () => {
	const f = tracker({ ignore: "[data-no-swipe]" });
	f.stroke([50, 400], [250, 400], { touches: 2 });
	f.stroke([50, 400], [250, 400], { target: { closest: (s) => (s === "[data-no-swipe]" ? {} : null) } });
	assert.deepEqual(f.swipes, []);
});

test("a cancelled touch forgets its start, and destroy detaches", () => {
	const f = tracker();
	f.listeners.get("touchstart")({ touches: [{ clientX: 50, clientY: 400 }], target: {} });
	f.listeners.get("touchcancel")();
	f.listeners.get("touchend")({ changedTouches: [{ clientX: 250, clientY: 400 }] });
	assert.deepEqual(f.swipes, []);
	f.t.destroy();
	assert.equal(f.listeners.size, 0);
});

test("a swipe on Home: right swaps anywhere; up edits or starts fresh only on an opened workout", () => {
	const closed = { chooserOpen: false, optionsOpen: false, expanded: false };
	assert.equal(gestureEvent("right", closed), "open_chooser");
	assert.equal(gestureEvent("up", closed), null);
	assert.equal(gestureEvent("left", closed), null);
	assert.equal(gestureEvent("down", closed), null);

	const opened = { ...closed, expanded: true };
	assert.equal(gestureEvent("up", opened), "open_options");
	assert.equal(gestureEvent("right", opened), "open_chooser");

	const drawer = { ...opened, chooserOpen: true };
	assert.equal(gestureEvent("left", drawer), "close_chooser");
	assert.equal(gestureEvent("up", drawer), null);

	const sheet = { ...opened, optionsOpen: true };
	assert.equal(gestureEvent("down", sheet), "close_options");
	assert.equal(gestureEvent("right", sheet), null);
});

test("swiping a value right raises it and left lowers it", () => {
	assert.equal(stepDirection("right"), "up");
	assert.equal(stepDirection("left"), "down");
	assert.equal(stepDirection("up"), null);
});
