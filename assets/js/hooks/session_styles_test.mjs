import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../../css/app.css", import.meta.url), "utf8");
const displayModel = readFileSync(
	new URL("session_display_model.mjs", import.meta.url),
	"utf8",
);
const renderer = readFileSync(
	new URL("session_renderer.mjs", import.meta.url),
	"utf8",
);
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

function hiddenByRule(selectors) {
	return selectors.some((selector) => {
		const declarations = ruleFor(selector)?.declarations || "";
		return /(?:display:\s*none|visibility:\s*hidden|opacity:\s*0)/.test(
			declarations,
		);
	});
}

function blockFor(marker, source = css) {
	const start = source.indexOf(marker);
	assert.notEqual(start, -1, `${marker} should exist`);
	const open = source.indexOf("{", start);
	let depth = 0;

	for (let index = open; index < source.length; index += 1) {
		if (source[index] === "{") depth += 1;
		if (source[index] === "}") depth -= 1;
		if (depth === 0) return source.slice(open + 1, index);
	}

	assert.fail(`${marker} should be closed`);
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
	"is-rest",
	"is-rest-count-in",
	"is-count-in",
];

test("runner and paused actions use fixed contrast-safe active tokens in both themes", () => {
	const lightTheme = ruleFor(".session-surface");
	const darkTheme = ruleFor('[data-theme="dark"] .session-surface');

	for (const theme of [lightTheme, darkTheme]) {
		assert.match(theme.declarations, /--session-active-bg:\s*#F3EEE8;/);
		assert.match(theme.declarations, /--session-active-ink:\s*#20201D;/);
		assert.match(theme.declarations, /--session-active-muted:\s*#706C64;/);
		assert.match(theme.declarations, /--session-track:\s*#DDD6CF;/);
	}

	assert.match(lightTheme.declarations, /--session-work:\s*#E86F47;/);
	assert.match(
		lightTheme.declarations,
		/--session-rest-light:\s*#D3DCEA;/,
	);
	assert.match(lightTheme.declarations, /--session-rest:\s*#5C7096;/);

	const runner = ruleFor("#session-runner-client")?.declarations || "";
	assert.match(
		runner,
		/--session-progress-track:\s*var\(--session-track\);/,
	);

	const workFill = ruleFor("#session-work-fill")?.declarations || "";
	assert.match(workFill, /background:\s*var\(--session-work\);/);
	assert.match(workFill, /clip-path:\s*inset\(100% 0 0 0\);/);
	assert.doesNotMatch(workFill, /linear-gradient|var\(--session-rest\)|opacity:/);
	assert.doesNotMatch(workFill, /transform:\s*scaleY/);
	assert.doesNotMatch(css, /#session-work-(?:track|threshold)/);
	assert.doesNotMatch(css, /#session-rest-shape/);
	assert.doesNotMatch(sessionLive, /session-work-(?:track|threshold)/);
	assert.doesNotMatch(sessionLive, /session-rest-shape/);

	for (const state of ["is-working", "is-rest-count-in", "is-count-in"]) {
		const declarations =
			ruleFor(`#session-runner-client.${state}`)?.declarations || "";
		assert.match(declarations, /background:\s*var\(--session-active-bg\)/);
	}

	for (const state of activeStates) {
		const declarations =
			ruleFor(`#session-runner-client.${state}`)?.declarations || "";
		assert.match(declarations, /color:\s*var\(--session-active-ink\)/);
	}

	const finish = ruleFor(".session-finish-early-action")?.declarations || "";
	assert.match(finish, /width:\s*100%;/);
	assert.match(finish, /min-height:\s*3\.75rem;/);
	assert.match(finish, /border:\s*0;/);
	assert.match(finish, /border-radius:\s*1\.25rem;/);
	assert.match(finish, /background:\s*var\(--session-active-ink\);/);
	assert.match(finish, /color:\s*var\(--session-active-bg\);/);
});

test("Abort uses the actual fixed active ink with normal-text contrast on every underlying field", () => {
	const abortClass = sessionLive.match(
		/id="session-abort-btn"[\s\S]*?class="([^"]+)"/,
	)?.[1];
	assert.ok(abortClass, "Abort should retain an explicit class list");
	assert.match(abortClass, /text-\[var\(--session-active-ink\)\]/);
	assert.doesNotMatch(abortClass, /text-\[var\(--session-active-muted\)\]/);

	for (const background of ["#F3EEE8", "#E86F47", "#7F95B5"]) {
		assert.ok(
			contrastRatio("#20201D", background) >= 4.5,
			`Abort foreground must pass normal-text contrast on ${background}`,
		);
	}
});

test("pause freezes the underlying full-screen rest breath", () => {
	const pausedRest =
		ruleFor("#session-runner-client.is-rest.is-paused")?.declarations || "";
	assert.match(pausedRest, /animation-play-state:\s*paused;/);
	assert.doesNotMatch(
		pausedRest,
		/(?:display:\s*none|visibility:\s*hidden|opacity\s*:\s*0)/,
	);
});

test("normal and intra-rep rest breathe across the full blue screen", () => {
	const breathing = blockFor("@keyframes session-blue-breathe");
	assert.match(
		breathing,
		/0%,\s*100%[^}]*background-color:\s*var\(--session-rest-light\);/,
	);
	assert.match(
		breathing,
		/50%[^}]*background-color:\s*var\(--session-rest\);/,
	);

	const rest = ruleFor("#session-runner-client.is-rest")?.declarations || "";
	assert.match(rest, /background:\s*var\(--session-rest-light\);/);
	assert.match(
		rest,
		/animation:\s*session-blue-breathe\s+5s\s+ease-in-out\s+infinite;/,
	);
	assert.doesNotMatch(rest, /border-radius:|transform:|opacity:/);
});

test("rest_count_in is paper-only with undecorated center content", () => {
	assert.equal(
		hiddenByRule([
			"#session-runner-client.is-rest-count-in #session-work-fill",
			"#session-runner-client:not(.is-working) #session-work-fill",
		]),
		true,
		"the orange work fill must be absent or hidden",
	);

	const state =
		ruleFor("#session-runner-client.is-rest-count-in")?.declarations || "";
	assert.match(state, /background:\s*var\(--session-active-bg\)/);
	assert.doesNotMatch(state, /var\(--session-(?:rest|work)\)/);

	const centerDeclarations = rules
		.filter((rule) =>
			rule.selectors.some(
				(selector) =>
					selector === "#ring-container" ||
					selector === "#count" ||
					(selector.includes(".is-rest-count-in") &&
						(selector.includes("#ring-container") ||
							selector.includes("#count"))),
			),
		)
		.map((rule) => rule.declarations)
		.join("\n");
	assert.doesNotMatch(
		centerDeclarations,
		/(?:border(?:-[a-z-]+)?|outline|box-shadow)\s*:|drop-shadow\(/,
	);

	const potentiallyActiveCenterDecorations = rules.filter(
		(rule) =>
			rule.selectors.some(
				(selector) =>
					/#(?:ring-container|count)[^,]*::(?:before|after)/.test(selector) &&
					!/#session-runner-client\.(?:is-working|is-rest(?!-count-in)|is-count-in)\b/.test(
						selector,
					),
			) &&
			/(?:content\s*:|border(?:-[a-z-]+)?\s*:|box-shadow\s*:|drop-shadow\()/.test(
				rule.declarations,
			),
	);
	assert.deepEqual(
		potentiallyActiveCenterDecorations,
		[],
		"rest_count_in must not inherit a center pseudo-element decoration",
	);

	assert.doesNotMatch(css, /session-countdown-halo/);
	assert.doesNotMatch(css, /is-between-set-pulse/);
	assert.doesNotMatch(
		css,
		/is-rest-count-in[^{}]*#(?:ring-container|count)[^{}]*::(?:before|after)/,
	);
});

test("count-in states hide progress and completed reps", () => {
	for (const state of ["is-count-in", "is-rest-count-in"]) {
		const topReadout =
			ruleFor(`#session-runner-client.${state} #session-top-readout`)
				?.declarations || "";
		assert.match(topReadout, /visibility:\s*hidden;/);
	}
});

test("state-specific CSS preserves the center and bottom anchor positions", () => {
	const stateClass =
		/\.(?:is-working|is-rest|is-rest-count-in|is-count-in|is-paused)\b/;
	const anchor = /#(?:ring-container|session-status-line)\b/;
	const positionalDeclaration =
		/(?:^|;)\s*(?:position|top|right|bottom|left|inset(?:-[a-z-]+)?|transform|translate|margin(?:-[a-z-]+)?)\s*:/;
	const stateSpecificAnchorRules = rules.filter((rule) =>
		rule.selectors.some(
			(selector) => stateClass.test(selector) && anchor.test(selector),
		),
	);

	for (const rule of stateSpecificAnchorRules) {
		assert.doesNotMatch(
			rule.declarations,
			positionalDeclaration,
			`${rule.selectors.join(", ")} must not move stable anchors between states`,
		);
	}
});

test("shared progress and contextual metrics preserve the premium hierarchy", () => {
	const progress = ruleFor("#session-progress")?.declarations || "";
	const progressFill = ruleFor("#session-progress-fill")?.declarations || "";
	const runnerLayout = ruleFor("#session-runner-layout")?.declarations || "";
	const setProgress = ruleFor("#set-progress")?.declarations || "";
	const status = ruleFor("#session-status-line")?.declarations || "";
	const total = ruleFor("#session-status-line #total-reps")?.declarations || "";

	assert.match(runnerLayout, /max-width:\s*none;/);
	assert.match(runnerLayout, /min-height:\s*100dvh;/);
	assert.match(progress, /height:\s*4px;/);
	assert.match(progress, /border-radius:\s*9999px;/);
	assert.match(progress, /background:\s*var\(--session-progress-track\);/);
	assert.match(progress, /overflow:\s*hidden;/);
	assert.match(progressFill, /transform:\s*scaleX\(0\);/);
	assert.match(progressFill, /transform-origin:\s*left center;/);
	assert.match(progressFill, /will-change:\s*transform;/);
	assert.match(status, /margin-top:\s*clamp\(1\.75rem,[^;]*2\.5rem\);/);
	assert.match(status, /justify-content:\s*flex-start;/);
	assert.match(total, /font-size:\s*clamp\(3\.25rem,[^;]*4\.5rem\);/);
	assert.match(total, /font-weight:\s*500;/);
	assert.match(
		setProgress,
		/inset-block-start:\s*calc\(50% \+ clamp\(6\.875rem, 20vw, 8\.75rem\)\);/,
	);
	assert.match(setProgress, /font-weight:\s*500;/);
	assert.doesNotMatch(css, /#session-status-line #time-left/);

	for (const state of ["is-working", "is-count-in"]) {
		assert.match(
			ruleFor(`#session-runner-client.${state} #session-progress-fill`)
				?.declarations || "",
			/background:\s*var\(--session-work\);/,
		);
	}
	for (const state of ["is-rest", "is-rest-count-in"]) {
		assert.match(
			ruleFor(`#session-runner-client.${state} #session-progress-fill`)
				?.declarations || "",
			/background:\s*var\(--session-rest\);/,
		);
	}

	const workCount =
		ruleFor("#session-runner-client.is-working #count")?.declarations || "";
	const restCount =
		ruleFor("#session-runner-client.is-rest #count")?.declarations || "";
	assert.match(
		workCount,
		/font-size:\s*clamp\(15rem,[^;]*55vw[^;]*45dvh[^;]*22\.5rem\);/,
	);
	assert.match(workCount, /font-weight:\s*500;/);
	assert.match(
		restCount,
		/font-size:\s*clamp\(9\.375rem,[^;]*37vw[^;]*31dvh[^;]*14\.375rem\);/,
	);
	assert.match(restCount, /font-weight:\s*500;/);

	const compactPortrait = blockFor("@media (max-width: 360px)");
	assert.doesNotMatch(
		compactPortrait,
		/#session-status-line #total-reps\s*\{/,
		"compact portrait must retain the 52px completed-rep floor",
	);
	assert.doesNotMatch(
		compactPortrait,
		/#set-progress\s*\{/,
		"compact portrait must retain the 38px set-progress floor",
	);
});

test("short landscape keeps the center and top readout visible", () => {
	const landscape = blockFor(
		"@media (orientation: landscape) and (max-height: 500px)",
	);

	assert.match(
		landscape,
		/#session-top-readout\s*\{[^}]*top:\s*max\([^}]*safe-area-inset-top[^}]*\);/,
	);
	assert.match(
		landscape,
		/#session-runner-client\.is-working #count\s*\{[^}]*font-size:\s*clamp\(7rem,\s*42dvh,\s*10rem\);/,
	);
	assert.match(
		landscape,
		/#session-runner-client\.is-working #count\.is-count-double\s*\{[^}]*font-size:\s*clamp\(6rem,\s*36dvh,\s*8\.5rem\);/,
	);
	assert.match(
		landscape,
		/#session-runner-client\.is-working #count\.is-count-long\s*\{[^}]*font-size:\s*clamp\(5rem,\s*30dvh,\s*7rem\);/,
	);
	assert.match(
		landscape,
		/#session-runner-client\.is-rest #count\s*\{[^}]*font-size:\s*clamp\(6rem,\s*34dvh,\s*8rem\);/,
	);
	assert.doesNotMatch(
		landscape,
		/#(?:count|session-top-readout|session-status-line|set-progress|total-reps)[^{]*\{[^}]*(?:display:\s*none|visibility:\s*hidden|opacity:\s*0|overflow:\s*hidden|text-overflow\s*:)/,
	);
});

test("scrollbars are hidden globally without clipping page overflow", () => {
	const scrollbarRules = css.match(
		/\*\s*\{\s*scrollbar-width:\s*none;\s*\}[\s\S]*?\*::-webkit-scrollbar\s*\{\s*display:\s*none;\s*\}/,
	)?.[0];

	assert.ok(scrollbarRules, "global Firefox and WebKit scrollbar rules must exist");
	assert.doesNotMatch(scrollbarRules, /overflow:\s*hidden;/);
	assert.doesNotMatch(css, /@media\s*\(max-width:\s*768px\)/);
});

test("deprecated rest aliases are absent from model, renderer, and styles", () => {
	const runnerSources = `${displayModel}\n${renderer}\n${css}`;
	assert.doesNotMatch(runnerSources, /rest-(?:breathe|settle|countdown)/);
});

test("reduced motion stops full-screen breathing without suppressing fills", () => {
	const reducedMotion = blockFor("@media (prefers-reduced-motion: reduce)");
	assert.match(
		reducedMotion,
		/#session-runner-client\.is-rest[\s\S]*animation:\s*none\s*!important;/,
	);
	assert.match(
		reducedMotion,
		/#session-runner-client\.is-rest\s*\{[^}]*background:\s*var\(--session-rest-light\);/,
	);
	assert.doesNotMatch(
		reducedMotion,
		/#session-work-fill[^{]*\{[^}]*(?:display:\s*none|visibility:\s*hidden|opacity:\s*0)/,
	);
});

test("numeric count-in and active values retain approved ink", () => {
	for (const state of activeStates) {
		for (const target of [
			"#count",
			"#pause-icon",
			"#session-status-line span",
		]) {
			const selector = `#session-runner-client.${state} ${target}`;
			assert.match(
				ruleFor(selector)?.declarations || "",
				/color:\s*var\(--session-active-ink\)/,
				`${selector} should use the active surface ink`,
			);
		}
	}

	assert.doesNotMatch(css, /\.countdown-dot/);
	assert.doesNotMatch(renderer, /renderCountdownDots/);
});
