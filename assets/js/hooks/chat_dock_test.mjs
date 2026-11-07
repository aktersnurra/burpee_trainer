import test from "node:test";
import assert from "node:assert/strict";
import { createChatDock, keyboardInset, KEYBOARD_MIN_PX } from "./chat_dock.mjs";

function fixture({ innerHeight = 800, viewport, scrollTo = "#ask", reduced = false, fine = false } = {}) {
	const listeners = { viewport: new Map(), win: new Map(), doc: new Map() };
	const timers = [];
	const props = new Map();
	const scrolls = [];
	const elListeners = new Map();
	const el = {
		dataset: { version: "a", scrollTo },
		offsetHeight: 120,
		addEventListener: (name, fn) => elListeners.set(name, fn),
		removeEventListener: (name) => elListeners.delete(name),
	};
	const vp = viewport && {
		...viewport,
		addEventListener: (name, fn) => listeners.viewport.set(name, fn),
		removeEventListener: (name) => listeners.viewport.delete(name),
	};
	const pinned = [];
	const win = {
		innerHeight,
		scrollY: 0,
		scrollTo: (x, y) => pinned.push([x, y]),
		visualViewport: vp,
		matchMedia: (query) => ({ matches: query.includes("reduced-motion") ? reduced : fine }),
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
	return {
		el,
		elListeners,
		win,
		doc,
		vp,
		listeners,
		props,
		scrolls,
		pinned,
		timers,
		dock: createChatDock({ el, win, doc }),
	};
}

function keydown(f, { value = "Make it 150", ...keys } = {}) {
	let sent = 0;
	let prevented = false;
	const field = { tagName: "TEXTAREA", value, form: { requestSubmit: () => sent++ } };
	f.elListeners.get("keydown")({
		key: "Enter",
		target: field,
		preventDefault: () => {
			prevented = true;
		},
		...keys,
	});
	return { sent, prevented };
}

test("with a mouse, Enter sends and Shift+Enter keeps its new line", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0 }, fine: true });
	f.dock.mount();

	assert.deepEqual(keydown(f), { sent: 1, prevented: true });
	assert.deepEqual(keydown(f, { shiftKey: true }), { sent: 0, prevented: false });
	assert.deepEqual(keydown(f, { isComposing: true }), { sent: 0, prevented: false });
	// An empty box sends nothing, and gains no blank line.
	assert.deepEqual(keydown(f, { value: "  " }), { sent: 0, prevented: true });

	f.dock.destroy();
	assert.equal(f.elListeners.size, 0);
});

test("on a touch screen, Enter is a new line", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0 }, fine: false });
	f.dock.mount();
	assert.deepEqual(keydown(f), { sent: 0, prevented: false });
});

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

test("the screen is as tall as what the keyboard leaves, and the page never slides under it", () => {
	const f = fixture({ viewport: { height: 800, offsetTop: 0, scale: 1 } });
	f.dock.mount();
	assert.equal(f.props.get("--viewport-height"), "800px");
	assert.equal(f.pinned.length, 0);

	// iOS slides the page up to reveal the box as the keyboard opens; the screen goes back to
	// the top, so the box rides the keyboard and the conversation scrolls inside the screen.
	f.vp.height = 480;
	f.vp.offsetTop = 320;
	f.listeners.viewport.get("scroll")();
	assert.deepEqual(f.pinned, [[0, 0]]);
	assert.equal(f.props.get("--viewport-height"), "480px");

	// Zoomed in, the owner pans on purpose: left alone.
	f.vp.scale = 2;
	f.vp.offsetTop = 100;
	f.listeners.viewport.get("scroll")();
	assert.equal(f.pinned.length, 1);

	f.dock.destroy();
	assert.equal(f.props.has("--viewport-height"), false);
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

test("lands on the keyboard from the dock's own edge, not from innerHeight", () => {
	// Safari's bars make innerHeight taller than where a fixed box rests (780); the lift is
	// measured from the box, and taking back its own lift keeps a second measure from drifting.
	const f = fixture({ viewport: { height: 800, offsetTop: 0 } });
	let lift = 0;
	f.el.getBoundingClientRect = () => ({ bottom: 780 - lift });
	f.dock.mount();
	assert.equal(f.props.get("--keyboard-inset"), "0px");

	f.vp.height = 480;
	f.listeners.viewport.get("resize")();
	lift = 300;
	assert.equal(f.props.get("--keyboard-inset"), "300px");
	assert.equal(f.props.get("--keyboard-open"), "1");
	f.listeners.viewport.get("resize")();
	assert.equal(f.props.get("--keyboard-inset"), "300px");
});
