import test from "node:test";
import assert from "node:assert/strict";
import ComposerCaret, { caretToEnd } from "./composer_caret.mjs";

function field(value, caret) {
	const calls = [];
	return {
		calls,
		value,
		scrollHeight: 90,
		scrollTop: 0,
		dataset: caret ? { caret } : {},
		focus: () => calls.push("focus"),
		setSelectionRange: (a, b) => calls.push(["select", a, b]),
	};
}

test("the cursor lands after the prefix, at the end of the message", () => {
	const el = field("Six-count · Even · 20 min\nAdditional request: ");
	caretToEnd(el);
	assert.deepEqual(el.calls, ["focus", ["select", el.value.length, el.value.length]]);
	assert.equal(el.scrollTop, 90);
});

test("only a box that asks for it takes the cursor when it appears", () => {
	const asks = field("abc", "end");
	ComposerCaret.mounted.call({ el: asks });
	assert.equal(asks.calls.length, 2);

	const plain = field("abc");
	ComposerCaret.mounted.call({ el: plain });
	assert.deepEqual(plain.calls, []);
});
