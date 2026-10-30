import test from "node:test";
import assert from "node:assert/strict";
import HomeHint, { MAX_VIEWS, noteSwipe, noteView, readHint, shouldShowHint } from "./home_hint.mjs";

function storage(initial = null, { refuses = false } = {}) {
	let value = initial;
	return {
		getItem: () => (refuses ? (() => { throw new Error("blocked"); })() : value),
		setItem: (_key, next) => {
			if (refuses) throw new Error("blocked");
			value = next;
		},
		peek: () => value,
	};
}

test("a new device has seen nothing and shows the hint", () => {
	assert.deepEqual(readHint(storage()), { views: 0, swiped: false });
	assert.equal(shouldShowHint(readHint(storage())), true);
});

test("the hint shows for a few visits, then stops", () => {
	const s = storage();
	const shown = Array.from({ length: MAX_VIEWS + 2 }, () => noteView(s));
	assert.deepEqual(shown, [true, true, true, false, false]);
});

test("the first swipe ends the hint at once", () => {
	const s = storage();
	assert.equal(noteView(s), true);
	noteSwipe(s);
	assert.equal(noteView(s), false);
	assert.equal(readHint(s).swiped, true);
});

test("damaged or refused storage shows the hint and never throws", () => {
	assert.deepEqual(readHint(storage("not json")), { views: 0, swiped: false });
	assert.deepEqual(readHint(storage('{"views":"x"}')), { views: 0, swiped: false });
	const blocked = storage(null, { refuses: true });
	assert.equal(noteView(blocked), true);
	assert.doesNotThrow(() => noteSwipe(blocked));
});

test("the hook reveals its element only when the hint is due", () => {
	const el = { hidden: true };
	const previous = globalThis.localStorage;
	globalThis.localStorage = storage();
	try {
		HomeHint.mounted.call({ el });
		assert.equal(el.hidden, false);
		noteSwipe();
		const second = { hidden: true };
		HomeHint.mounted.call({ el: second });
		assert.equal(second.hidden, true);
	} finally {
		globalThis.localStorage = previous;
	}
});
