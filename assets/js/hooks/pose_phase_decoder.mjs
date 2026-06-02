import { scorePhaseEmissions } from "./pose_phase_emissions.mjs";

export const ALLOWED_TRANSITIONS = Object.freeze({
	unknown: ["unknown", "top_anchor", "descending", "bottom", "rising"],
	top_anchor: ["top_anchor", "descending", "rest_standing", "unknown"],
	rest_standing: ["rest_standing", "descending", "unknown"],
	descending: ["descending", "bottom", "unknown"],
	bottom: ["bottom", "rising", "unknown"],
	rising: ["rising", "top_anchor", "unknown"],
});

export function decodeBurpeePhases(frames) {
	const states = [];
	let previous = null;
	let score = 0;
	let illegalTransitionCount = 0;
	let currentUnknownMs = 0;
	let maxUnknownMs = 0;

	for (const frame of frames) {
		const emissions = scorePhaseEmissions(frame);
		let phase = winner(emissions);

		if (previous && !ALLOWED_TRANSITIONS[previous].includes(phase)) {
			illegalTransitionCount += 1;
			phase = "unknown";
		}

		score += emissions[phase] ?? 0;
		states.push(phase);

		if (phase === "unknown") {
			currentUnknownMs += frameDurationMs(frames, states.length - 1);
			maxUnknownMs = Math.max(maxUnknownMs, currentUnknownMs);
		} else {
			currentUnknownMs = 0;
		}

		previous = phase;
	}

	const segments = segmentsFromStates(frames, states);
	return {
		states,
		score: round4(score),
		segments,
		diagnostics: {
			emissionScoreMean:
				states.length === 0 ? 0 : round4(score / states.length),
			transitionPenalty: illegalTransitionCount,
			durationPenalty: 0,
			occlusionPenalty: round4(maxUnknownMs / 1000),
			illegalTransitionCount,
			maxUnknownMs,
		},
	};
}

function segmentsFromStates(frames, states) {
	if (states.length === 0) return [];
	const segments = [];
	let phase = states[0];
	let startMs = frames[0].tMs;

	for (let index = 1; index < states.length; index++) {
		if (states[index] === phase) continue;
		segments.push({ phase, startMs, endMs: frames[index - 1].tMs });
		phase = states[index];
		startMs = frames[index].tMs;
	}

	segments.push({ phase, startMs, endMs: frames[frames.length - 1].tMs });
	return segments;
}

function winner(scores) {
	return Object.entries(scores).sort((a, b) => b[1] - a[1])[0][0];
}

function frameDurationMs(frames, index) {
	if (frames.length <= 1) return 0;
	if (index === 0) return frames[1].tMs - frames[0].tMs;
	return frames[index].tMs - frames[index - 1].tMs;
}

function round4(value) {
	const rounded = Math.round(value * 10000) / 10000;
	return Object.is(rounded, -0) ? 0 : rounded;
}
