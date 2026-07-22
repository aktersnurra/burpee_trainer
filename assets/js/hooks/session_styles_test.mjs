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
		assert.match(theme.declarations, /--session-active-bg:\s*#F4F2EE;/);
		assert.match(theme.declarations, /--session-active-ink:\s*#20201D;/);
		assert.match(theme.declarations, /--session-active-muted:\s*#706C64;/);
	}

	assert.match(lightTheme.declarations, /--session-work:\s*#FD7236;/);
	assert.match(lightTheme.declarations, /--session-rest:\s*#749CCE;/);

	const workFieldRules = rules
		.filter((rule) =>
			rule.selectors.some((selector) =>
				["#session-work-track", "#session-work-fill"].includes(selector),
			),
		)
		.map((rule) => rule.declarations)
		.join("\n");
	assert.match(
		workFieldRules,
		/linear-gradient\([^;]*var\(--session-work\)[^;]*var\(--session-active-ratio\)[^;]*var\(--session-rest\)/,
	);
	assert.match(workFieldRules, /opacity:\s*0\.16;/);
	assert.match(workFieldRules, /clip-path:\s*inset\(100% 0 0 0\);/);
	assert.doesNotMatch(workFieldRules, /transform:\s*scaleY/);

	for (const state of activeStates) {
		const declarations =
			ruleFor(`#session-runner-client.${state}`)?.declarations || "";
		assert.match(declarations, /background:\s*var\(--session-active-bg\)/);
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

	for (const background of ["#F4F2EE", "#FD7236", "#749CCE"]) {
		assert.ok(
			contrastRatio("#20201D", background) >= 4.5,
			`Abort foreground must pass normal-text contrast on ${background}`,
		);
	}
});

test("pause preserves the underlying active field", () => {
	const pausedRest =
		ruleFor("#session-runner-client.is-paused #session-rest-shape")
			?.declarations || "";
	assert.match(pausedRest, /animation-play-state:\s*paused;/);
	assert.doesNotMatch(
		pausedRest,
		/(?:display:\s*none|visibility:\s*hidden|opacity\s*:|background\s*:)/,
	);

	const pausedFieldRules = rules
		.filter((rule) =>
			rule.selectors.some(
				(selector) =>
					selector.includes(".is-paused") &&
					/(?:#session-work-fill|#session-rest-shape)/.test(selector),
			),
		)
		.map((rule) => rule.declarations)
		.join("\n");
	assert.doesNotMatch(
		pausedFieldRules,
		/(?:display:\s*none|visibility:\s*hidden|opacity\s*:\s*0)/,
	);
});

test("normal rest is a centered soft-dome breathing field", () => {
	const shape = ruleFor("#session-rest-shape")?.declarations || "";
	assert.match(shape, /inset-inline-start:\s*-15%;/);
	assert.match(shape, /width:\s*130%;/);
	assert.match(shape, /height:\s*70dvh;/);
	assert.match(
		shape,
		/border-radius:\s*50% 50% 0 0 \/ 12dvh 12dvh 0 0;/,
	);
	assert.match(shape, /transform:\s*translateY\(21dvh\);/);
	assert.match(shape, /background:\s*var\(--session-rest\);/);

	const breathing = blockFor("@keyframes session-breathe");
	const outerPosition = Number(
		breathing.match(/0%,\s*100%[^}]*translateY\(([\d.]+)dvh\)/)?.[1],
	);
	const innerPosition = Number(
		breathing.match(/50%[^}]*translateY\(([\d.]+)dvh\)/)?.[1],
	);
	assert.equal(outerPosition, 26);
	assert.equal(innerPosition, 16);
	assert.equal(outerPosition - innerPosition, 10);

	const rest =
		ruleFor("#session-runner-client.is-rest #session-rest-shape")
			?.declarations || "";
	assert.match(rest, /opacity:\s*1;/);
	assert.match(rest, /background:\s*var\(--session-rest\);/);
	assert.doesNotMatch(rest, /border-radius:/);
	assert.match(rest, /animation:\s*session-breathe\s+5s\s+infinite;/);
});

test("rest_count_in is paper-only with undecorated center content", () => {
	assert.equal(
		hiddenByRule([
			"#session-runner-client.is-rest-count-in #session-rest-shape",
			"#session-runner-client:not(.is-rest) #session-rest-shape",
		]),
		true,
		"the blue rest shape must be absent or hidden",
	);
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
	const status = ruleFor("#session-status-line")?.declarations || "";
	const total = ruleFor("#session-status-line #total-reps")?.declarations || "";

	assert.match(runnerLayout, /max-width:\s*none;/);
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

	assert.match(
		ruleFor("#session-runner-client.is-working #count")?.declarations || "",
		/font-size:\s*clamp\(15rem,[^;]*55vw[^;]*45dvh[^;]*22\.5rem\);/,
	);
	assert.match(
		ruleFor("#session-runner-client.is-rest #count")?.declarations || "",
		/font-size:\s*clamp\(9\.375rem,[^;]*37vw[^;]*31dvh[^;]*14\.375rem\);/,
	);

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

test("reduced motion stops continuous breathing without suppressing discrete fills", () => {
	const reducedMotion = blockFor("@media (prefers-reduced-motion: reduce)");
	assert.match(
		reducedMotion,
		/#session-rest-shape[\s\S]*animation:\s*none\s*!important;/,
	);
	assert.match(
		reducedMotion,
		/#session-rest-shape\s*\{[^}]*transform:\s*translateY\(21dvh\);/,
	);
	assert.doesNotMatch(
		reducedMotion,
		/#session-work-fill[^{]*\{[^}]*(?:display:\s*none|visibility:\s*hidden|opacity:\s*0)/,
	);
	assert.doesNotMatch(
		reducedMotion,
		/#session-rest-shape[^{]*\{[^}]*(?:display:\s*none|visibility:\s*hidden|opacity:\s*0)/,
	);
});

test("count-in dots and active values retain approved ink", () => {
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

	const dot =
		ruleFor("#session-runner-client.is-count-in #count .countdown-dot")
			?.declarations || "";
	assert.match(dot, /background:\s*var\(--session-active-ink\)\s*!important;/);
});
