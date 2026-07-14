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

function keyframesFor(name) {
	const start = css.indexOf(`@keyframes ${name}`);
	assert.notEqual(start, -1, `${name} keyframes should exist`);
	const open = css.indexOf("{", start);
	let depth = 0;

	for (let index = open; index < css.length; index += 1) {
		if (css[index] === "{") depth += 1;
		if (css[index] === "}") depth -= 1;
		if (depth === 0) return css.slice(open + 1, index);
	}

	assert.fail(`${name} keyframes should be closed`);
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

const activeStates = [
	"is-working",
	"is-rest-breathe",
	"is-rest-settle",
	"is-rest-countdown",
	"is-initial-countdown",
];

test("active runner uses fixed contrast-safe paper and ink in both themes", () => {
	const lightTheme = ruleFor(".session-surface");
	const darkTheme = ruleFor('[data-theme="dark"] .session-surface');

	for (const theme of [lightTheme, darkTheme]) {
		assert.match(theme.declarations, /--session-active-bg:\s*#F4F2EE;/);
		assert.match(theme.declarations, /--session-active-ink:\s*#20201D;/);
	}

	for (const background of ["#F4F2EE", "#FD7236", "#749CCE"]) {
		const ratio = contrastRatio("#20201D", background);
		assert.ok(ratio >= 3, `${background} must pass large-text contrast`);
		assert.ok(ratio >= 4.5, `${background} must pass label-text contrast`);
	}

	for (const state of activeStates) {
		const selector = `#session-runner-client.${state}`;
		const declarations = ruleFor(selector)?.declarations || "";
		assert.match(declarations, /background:\s*var\(--session-active-bg\)/);
		assert.match(declarations, /color:\s*var\(--session-active-ink\)/);
	}
});

test("active numerals, values, labels, and pause glyph use active surface ink", () => {
	for (const state of activeStates) {
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

test("rest settle is a finite pausable animation with a static countdown endpoint", () => {
	const settleFrames = keyframesFor("session-rest-settle");
	assert.match(
		settleFrames,
		/from\s*\{[\s\S]*background:\s*var\(--session-rest\);[\s\S]*border-radius:\s*50% 50% 0 0 \/ 14% 14% 0 0;[\s\S]*transform:\s*scaleY\(1\.04\);/,
	);
	assert.match(
		settleFrames,
		/to\s*\{[\s\S]*background:\s*var\(--session-work\);[\s\S]*border-radius:\s*0;[\s\S]*transform:\s*scaleY\(0\.5\);/,
	);

	const settleSelector =
		"#session-runner-client.is-rest-settle #session-rest-shape";
	const settle = ruleFor(settleSelector)?.declarations || "";
	assert.match(settle, /animation:\s*session-rest-settle\s+700ms[^;]*\bboth;/);
	assert.doesNotMatch(settle, /transition\s*:/);

	const countdown =
		ruleFor("#session-runner-client.is-rest-countdown #session-rest-shape")
			?.declarations || "";
	assert.match(countdown, /animation:\s*none;/);
	assert.match(countdown, /background:\s*var\(--session-work\)/);
	assert.match(countdown, /border-radius:\s*0;/);
	assert.match(countdown, /transform:\s*scaleY\(0\.5\);/);

	const pausedSelector = "#session-runner-client.is-paused #session-rest-shape";
	assert.match(
		ruleFor(pausedSelector)?.declarations || "",
		/animation-play-state:\s*paused;/,
	);
	assert.ok(css.lastIndexOf(pausedSelector) > css.indexOf(settleSelector));
});
