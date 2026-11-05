import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const css = readFileSync(new URL("../../css/app.css", import.meta.url), "utf8");

function blockFor(marker) {
	const start = css.indexOf(marker);
	assert.notEqual(start, -1, `${marker} should exist`);
	const open = css.indexOf("{", start);
	let depth = 0;

	for (let index = open; index < css.length; index += 1) {
		if (css[index] === "{") depth += 1;
		if (css[index] === "}") depth -= 1;
		if (depth === 0) return css.slice(open + 1, index);
	}

	assert.fail(`${marker} should be closed`);
}

test("reduced motion steps the set's fill without hiding runner information", () => {
	const reducedMotion = blockFor("@media (prefers-reduced-motion: reduce)");
	assert.match(
		reducedMotion,
		/#session-work-fill,[\s\S]*#session-work-line[\s\S]*transition:\s*none\s*!important;/,
	);
	for (const selector of ["#count", "#session-pause-actions", "#set-progress"]) {
		assert.doesNotMatch(
			reducedMotion,
			new RegExp(`${selector}[^{]*\\{[^}]*(?:display:\\s*none|visibility:\\s*hidden|opacity:\\s*0)`),
			`${selector} must remain available under reduced motion`,
		);
	}
});

test("the runner's chips keep a 44px touch target", () => {
	const chip = blockFor(".session-night .session-chip {");
	assert.match(chip, /width:\s*var\(--pill-h\);/);
	assert.match(chip, /height:\s*var\(--pill-h\);/);
	const tokens = readFileSync(new URL("../../css/adaptive_home.css", import.meta.url), "utf8");
	assert.match(tokens, /--pill-h:\s*(4[4-9]|[5-9]\d)px/);
});

test("the preflight back control retains a 44px touch target", () => {
	const control = blockFor("#burpee-session .session-preflight-back");
	assert.match(control, /width:\s*44px;/);
	assert.match(control, /height:\s*44px;/);
});
