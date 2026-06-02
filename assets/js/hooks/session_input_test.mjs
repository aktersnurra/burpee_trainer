import assert from "node:assert/strict";
import test from "node:test";

import { isPauseToggleKey } from "./session_input.mjs";

test("treats Enter and Space as pause toggle keys", () => {
	assert.equal(isPauseToggleKey({ key: "Enter" }), true);
	assert.equal(isPauseToggleKey({ key: " " }), true);
});

test("ignores other keys for pause toggling", () => {
	assert.equal(isPauseToggleKey({ key: "Escape" }), false);
	assert.equal(isPauseToggleKey({ key: "ArrowDown" }), false);
});
