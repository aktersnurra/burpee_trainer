import test from "node:test";
import assert from "node:assert/strict";
import { createChatDock, keyboardInset, KEYBOARD_MIN_PX } from "./chat_dock.mjs";

function fixture({ innerHeight = 800, viewport, scrollTo = "#ask", reduced = false } = {}) {
	const listeners = { viewport: new Map(), win: new Map(), doc: new Map() };
	const timers = [];
	const props = new Map();
	const scrolls = [];
	const el = { dataset: { version: "a", scrollTo }, offsetHeight: 120 };
	const vp = viewport && {
		...viewport,
		addEventListener: (name, fn) => listeners.viewport.set(name, fn),
		removeEventListener: (name) => listeners.viewport.delete(name),
	};
	const win = {
		innerHeight,
		visualViewport: vp,
		matchMedia: () => ({ matches: reduced }),
		addEventListener: (name, fn) => listeners.win.set(name, fn),
		removeEventListener: (name) => listeners.win.delete(name),
		setTimeout: (fn, ms) => timers.push({ fn, ms }),
	};
	const doc = {
		addEventListener: (name, fn) => listeners.doc.set(name, fn),
		removeEventListener: (name) => listeners.doc.delete(name),
		documentElement: {
			style: {
				setProperty: (k, v) => props.set(k, v),
				removeProperty: (k) => props.delete(k),
			},
		},
		querySelector: (selector) =>
			selector === "#ask" ? { scrollIntoView: (o) => scrolls.push(o) } : null,
	};
	return { el, win, doc, vp, listeners, props, scrolls, timers, dock: createChatDock({ el, win, doc }) };
}

test("the inset is the gap the keyboard leaves under the visual viewport", () => {
	assert.equal(keyboardInset({ innerHeight: 800, viewport: { height: 500, offsetTop: 0 } }), 300);
	// The page scrolled to reveal the field: the viewport sits lower, so the gap is smaller.
	assert.equal(keyboardInset({ innerHeight: 800, viewport: { height: 500, offsetTop: 120 } }), 180);
	assert.equal(keyboardInset({ innerHeight: 800, viewport: { height: 800, offsetTop: 0 } }), 0);
	assert.equal(keyboardInset({ innerHeight: 800, viewport: { height: 900, offsetTop: 0 } }), 0);
	assert.equal(keyboardInset({ innerHeight: 800, viewport: undefined }), 0);
});

test("lifts above the keyboard and follows it as it opens and closes", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0 } });
	f.dock.mount();
	assert.equal(f.props.get("--keyboard-inset"), "0px");
	assert.equal(f.props.get("--chat-dock-height"), "120px");
	assert.equal(f.el.dataset.keyboard, "closed");

	f.vp.height = 480;
	f.listeners.viewport.get("resize")();
	assert.equal(f.props.get("--keyboard-inset"), "320px");
	assert.equal(f.el.dataset.keyboard, "open");

	f.vp.height = 800 - KEYBOARD_MIN_PX + 10;
	f.listeners.viewport.get("scroll")();
	assert.equal(f.el.dataset.keyboard, "closed");
});

test("brings the newest message into view when the conversation moves on, not on every patch", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0 } });
	f.dock.mount();
	assert.equal(f.scrolls.length, 1);
	assert.deepEqual(f.scrolls[0], { behavior: "smooth", block: "start" });

	f.dock.update();
	assert.equal(f.scrolls.length, 1);

	f.el.dataset.version = "b";
	f.dock.update();
	assert.equal(f.scrolls.length, 2);
});

test("a dock that opts out stays where it is on mount but still follows the conversation", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0 } });
	f.el.dataset.scrollOnMount = "false";
	f.dock.mount();
	assert.equal(f.scrolls.length, 0);
	f.el.dataset.version = "b";
	f.dock.update();
	assert.equal(f.scrolls.length, 1);
});

test("scrolls without animation for reduced motion, and tolerates a missing target", () => {
	const reduced = fixture({ viewport: { height: 800, offsetTop: 0 }, reduced: true });
	reduced.dock.mount();
	assert.equal(reduced.scrolls[0].behavior, "auto");

	const none = fixture({ viewport: { height: 800, offsetTop: 0 }, scrollTo: "#missing" });
	none.dock.mount();
	assert.equal(none.scrolls.length, 0);
});

test("works without visualViewport and cleans up after itself", () => {
	const f = fixture({ viewport: undefined });
	f.dock.mount();
	assert.equal(f.props.get("--keyboard-inset"), "0px");
	f.dock.destroy();
	assert.equal(f.props.size, 0);
	assert.equal(f.listeners.win.size, 0);
});

test("a focus change measures again once the keyboard has settled", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0 } });
	f.dock.mount();
	f.vp.height = 480;
	f.listeners.doc.get("focusin")();
	assert.equal(f.props.get("--keyboard-inset"), "320px");

	// The keyboard moves on after the first measure; the second, later, catches where it stopped.
	f.vp.height = 460;
	assert.deepEqual(f.timers.map((t) => t.ms), [350]);
	f.timers[0].fn();
	assert.equal(f.props.get("--keyboard-inset"), "340px");

	f.dock.destroy();
	assert.equal(f.listeners.doc.size, 0);
});
