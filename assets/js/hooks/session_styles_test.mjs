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

test("reduced motion disables full-screen rest breathing without hiding runner information", () => {
	const reducedMotion = blockFor("@media (prefers-reduced-motion: reduce)");
	assert.match(
		reducedMotion,
		/#session-rest-breathe-light,[\s\S]*#session-rest-breathe-dark[\s\S]*animation:\s*none\s*!important;/,
	);
	for (const selector of ["#count", "#session-status-line", "#session-pause-actions"]) {
		assert.doesNotMatch(
			reducedMotion,
			new RegExp(`${selector}[^{]*\\{[^}]*(?:display:\\s*none|visibility:\\s*hidden|opacity:\\s*0)`),
			`${selector} must remain available during reduced-motion rest`,
		);
	}
	assert.match(reducedMotion, /#count,[\s\S]*#session-pause-actions[\s\S]*animation:\s*none\s*!important;/);
});

test("the preflight back control retains a 44px touch target", () => {
	const control = blockFor("#burpee-session .session-preflight-back");
	assert.match(control, /width:\s*44px;/);
	assert.match(control, /height:\s*44px;/);
});
