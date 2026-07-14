import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../../css/app.css", import.meta.url), "utf8");
const sessionLive = readFileSync(
	new URL(
		"../../../lib/burpee_trainer_web/live/session_live.ex",
		import.meta.url,
	),
	"utf8",
);
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

test("active numerals, values, labels, pause glyph, and countdown dots use active surface ink", () => {
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

	const dot = ruleFor(
		"#session-runner-client.is-initial-countdown #count .countdown-dot",
	)?.declarations;
	assert.match(
		dot || "",
		/background:\s*var\(--session-active-ink\)\s*!important;/,
	);

	for (const [theme, foreground, background] of [
		["light", "#20201D", "#F4F2EE"],
		["dark", "#20201D", "#F4F2EE"],
	]) {
		assert.ok(
			contrastRatio(foreground, background) >= 4.5,
			`${theme} countdown dots must contrast with their active background`,
		);
	}
});

test("between-set numerals retain dark ink while a work-orange halo pulses", () => {
	const count = ruleFor("#count.is-between-set-pulse")?.declarations || "";
	assert.match(count, /color:\s*var\(--session-active-ink\);/);
	assert.match(count, /position:\s*relative;/);

	const halo =
		ruleFor("#count.is-between-set-pulse.countdown-pop::after")?.declarations ||
		"";
	assert.match(halo, /content:\s*"";/);
	assert.match(halo, /border:[^;]*solid var\(--session-work\);/);
	assert.match(halo, /animation:\s*session-countdown-halo\s+0\.35s[^;]*;/);

	const frames = keyframesFor("session-countdown-halo");
	assert.match(frames, /0%[\s\S]*opacity:\s*0;/);
	assert.match(frames, /40%[\s\S]*opacity:\s*1;/);
	assert.match(frames, /100%[\s\S]*opacity:\s*0;/);
});

test("pause actions reserve a separate normal-flow row above stable stats", () => {
	const layout = ruleFor("#session-runner-layout")?.declarations || "";
	assert.match(layout, /display:\s*grid;/);
	assert.match(
		layout,
		/grid-template-rows:\s*minmax\(0,\s*1fr\)\s+auto\s+auto;/,
	);

	const actions = ruleFor("#session-pause-actions")?.declarations || "";
	assert.match(actions, /position:\s*relative;/);
	assert.match(actions, /grid-row:\s*2;/);
	assert.match(actions, /margin-bottom:\s*1rem;/);
	assert.doesNotMatch(actions, /position:\s*absolute;/);

	const status = ruleFor("#session-status-line")?.declarations || "";
	assert.match(status, /grid-row:\s*3;/);
});

test("muted supporting text meets normal-text contrast in both themes", () => {
	const lightTheme = ruleFor(".session-surface")?.declarations || "";
	const darkTheme =
		ruleFor('[data-theme="dark"] .session-surface')?.declarations || "";
	assert.match(lightTheme, /--session-muted:\s*#706C64;/);
	assert.match(darkTheme, /--session-muted:\s*#AAB2BE;/);

	for (const [theme, foreground, background] of [
		["light", "#706C64", "#F4F2EE"],
		["dark", "#AAB2BE", "#111318"],
	]) {
		assert.ok(
			contrastRatio(foreground, background) >= 4.5,
			`${theme} muted text must pass normal-text contrast`,
		);
	}

	assert.match(
		sessionLive,
		/for="completion-note-input"[\s\S]*?class="[^"]*text-sm[^"]*text-\[var\(--session-muted\)\]"/,
	);
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
