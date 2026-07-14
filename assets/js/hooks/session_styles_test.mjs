import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../../css/app.css", import.meta.url), "utf8");
const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(
	([, selectors, declarations]) => ({
		selectors: selectors.split(",").map((selector) => selector.trim()),
		declarations,
	}),
);

function ruleFor(selector) {
	return rules.find((rule) => rule.selectors.includes(selector));
}

function luminance(hex) {
	const channels = hex
		.slice(1)
		.match(/.{2}/g)
		.map((channel) => Number.parseInt(channel, 16) / 255)
		.map((channel) =>
			channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
		);
	return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function contrastRatio(first, second) {
	const lighter = Math.max(luminance(first), luminance(second));
	const darker = Math.min(luminance(first), luminance(second));
	return (lighter + 0.05) / (darker + 0.05);
}

test("active surface ink stays dark and contrast-safe in both themes", () => {
	const lightTheme = ruleFor(".session-surface");
	const darkTheme = ruleFor('[data-theme="dark"] .session-surface');

	assert.match(lightTheme.declarations, /--session-active-ink:\s*#20201D;/);
	assert.match(darkTheme.declarations, /--session-active-ink:\s*#20201D;/);
	assert.ok(contrastRatio("#20201D", "#FD7236") >= 4.5);
	assert.ok(contrastRatio("#20201D", "#749CCE") >= 4.5);
});

test("active numerals, values, labels, and pause glyph use active surface ink", () => {
	for (const state of [
		"is-working",
		"is-rest-breathe",
		"is-rest-settle",
		"is-rest-countdown",
	]) {
		for (const target of [
			"#count",
			"#pause-icon",
			"#session-status-line > div > span",
		]) {
			const selector = `#session-runner-client.${state} ${target}`;
			assert.match(
				ruleFor(selector)?.declarations || "",
				/color:\s*var\(--session-active-ink\)/,
				`${selector} should use the active surface ink`,
			);
		}
	}
});
