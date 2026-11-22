import test from "node:test";
import assert from "node:assert/strict";
import NumberNudge, { NUDGE_PX, nudge } from "./number_nudge.mjs";

function number(reduced = false) {
	const animations = [];
	const el = {
		value: "20",
		ownerDocument: { activeElement: null },
		animate: (keyframes, options) => {
			const animation = { keyframes, options, cancelled: false, cancel() { this.cancelled = true; } };
			animations.push(animation);
			return animation;
		},
		getAnimations: () => animations.filter((a) => !a.cancelled),
	};
	const win = { matchMedia: (query) => ({ matches: reduced && query.includes("reduce") }) };
	return { el, win, animations };
}

const start = (animation) => animation.keyframes[0].transform;

test("a number stepped up rises into place and one stepped down drops into it", () => {
	const { el, win, animations } = number();
	nudge(el, "20", "21", win);
	nudge(el, "21", "20", win);
	assert.deepEqual(animations.map(start), [`translateY(${NUDGE_PX}px)`, `translateY(-${NUDGE_PX}px)`]);
});

test("a held stepper restarts the move instead of stacking it", () => {
	const { el, win, animations } = number();
	nudge(el, "20", "21", win);
	nudge(el, "21", "22", win);
	assert.equal(animations[0].cancelled, true);
	assert.equal(el.getAnimations().length, 1);
});

test("an unchanged or unreadable value does not move", () => {
	const { el, win, animations } = number();
	nudge(el, "20", "20", win);
	nudge(el, "—", "112", win);
	assert.equal(animations.length, 0);
});

test("reduced motion keeps the number still", () => {
	const { el, win, animations } = number(true);
	nudge(el, "20", "21", win);
	assert.equal(animations.length, 0);
});

test("the hook moves a value the server changed, never one being typed", () => {
	const { el, win, animations } = number();
	const hook = { ...NumberNudge, el, win };
	hook.mounted();
	el.value = "25";
	hook.updated();
	el.ownerDocument.activeElement = el;
	el.value = "30";
	hook.updated();
	assert.equal(animations.length, 1);
	assert.equal(start(animations[0]), `translateY(${NUDGE_PX}px)`);
});
