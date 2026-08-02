import assert from "node:assert/strict";
import test from "node:test";

import { isPauseToggleKey } from "./session_input.mjs";

test("pause accepts Enter and standard or named Space key events", () => {
	assert.equal(isPauseToggleKey({ key: "Enter", code: "Enter" }), true);
	assert.equal(isPauseToggleKey({ key: " ", code: "Space" }), true);
	assert.equal(isPauseToggleKey({ key: "Space", code: "Space" }), true);
	assert.equal(isPauseToggleKey({ key: "Escape", code: "Escape" }), false);
});
