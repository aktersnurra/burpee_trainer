const PHASES = Object.freeze([
	"standing",
	"lowering",
	"pushup",
	"rising",
]);

const NEXT = Object.freeze({
	standing: ["standing", "lowering"],
	lowering: ["lowering", "pushup"],
	pushup: ["pushup", "rising"],
	rising: ["rising", "standing"],
});

const REFRACTORY_MS = 900;
const MIN_CONFIDENCE = 0.5;
const MIN_MACRO_LANDMARK_CONFIDENCE = 0.5;
const MIN_VISIBLE_FRACTION = 0.35;
const FORWARD_EMISSION = 0.72;
const RETURN_TO_STANDING_EMISSION = 0.47;
const RISING_MIN_BODY_VERTICAL_SPAN = 1.1;

export function initialBurpeeHsmmState() {
	return {
		phase: "standing",
		phaseStartedAtMs: null,
		lastRepAtMs: null,
		cadenceMs: [],
	};
}

export function stepBurpeeHsmm(state, frame) {
	if (!usable(frame)) {
		return { state: preservePushupCandidate(state), rep: false, repAtMs: null };
	}

	const emissions = scoreMacroEmissions(frame);
	if (strongOutOfOrderEmission(state, emissions)) {
		return { state: resetCandidate(state), rep: false, repAtMs: null };
	}

	const phase = nextPhase(state, emissions, frame);
	const next = transition(state, phase, frame.tMs);
	const rep =
		state.phase === "rising" &&
		phase === "standing" &&
		outsideRefractory(state, frame.tMs);

	return {
		state: rep ? recordRep(next, frame.tMs) : next,
		rep,
		repAtMs: rep ? frame.tMs : null,
	};
}

function usable(frame) {
	return (
		Number.isFinite(frame?.tMs) &&
		frame?.hasFullWorldLandmarkCoverage === true &&
		finiteOr(frame.poseConfidence, frame.confidence) >= MIN_CONFIDENCE &&
		finiteOr(frame.macroLandmarkConfidence, 0) >=
			MIN_MACRO_LANDMARK_CONFIDENCE &&
		finiteOr(frame.visibleFraction, 0) >= MIN_VISIBLE_FRACTION &&
		[
			frame.worldBodyVerticalSpan,
			frame.worldHipVerticalSpan,
			frame.worldTorsoElevation,
			frame.worldWristVerticalSpan,
			frame.dWorldBodyVerticalSpan,
			frame.dWorldWristVerticalSpan,
		].every(Number.isFinite)
	);
}

function scoreMacroEmissions(frame) {
	return {
		standing: weightedScore([
			[rises(frame.worldBodyVerticalSpan, 2.8, 3.2), 0.35],
			[rises(frame.worldHipVerticalSpan, 1.6, 2.0), 0.2],
			[rises(frame.worldTorsoElevation, 0.75, 0.85), 0.25],
			[rises(frame.worldWristVerticalSpan, 1.2, 1.5), 0.2],
		]),
		lowering: weightedScore([
			[band(frame.worldBodyVerticalSpan, 1.1, 2.1, 3.2), 0.35],
			[falls(frame.worldTorsoElevation, 0.8, 0.45), 0.2],
			[falls(frame.worldWristVerticalSpan, 1.6, 0.7), 0.15],
			[falls(frame.dWorldBodyVerticalSpan, -0.25, -0.8), 0.3],
		]),
		pushup: weightedScore([
			[falls(frame.worldBodyVerticalSpan, 1.5, 1.1), 0.3],
			[falls(frame.worldHipVerticalSpan, 1.0, 0.7), 0.2],
			[falls(frame.worldTorsoElevation, 0.5, 0.35), 0.3],
			[falls(frame.worldWristVerticalSpan, 0.8, 0.45), 0.2],
		]),
		rising: weightedScore([
			[
				band(
					frame.worldBodyVerticalSpan,
					RISING_MIN_BODY_VERTICAL_SPAN,
					2.1,
					3.2,
				),
				0.25,
			],
			[band(frame.worldTorsoElevation, 0.3, 0.55, 0.85), 0.2],
			[rises(frame.worldHipVerticalSpan, 0.7, 1.1), 0.15],
			[rises(frame.dWorldBodyVerticalSpan, 0.25, 0.8), 0.4],
		]),
	};
}

function rises(value, zeroAt, fullAt) {
	return clamp01((value - zeroAt) / (fullAt - zeroAt));
}

function falls(value, zeroAt, fullAt) {
	return clamp01((zeroAt - value) / (zeroAt - fullAt));
}

function band(value, low, center, high) {
	return value <= center
		? rises(value, low, center)
		: falls(value, high, center);
}

function weightedScore(entries) {
	return entries.reduce((total, [score, weight]) => total + score * weight, 0);
}

function clamp01(value) {
	if (value < 0) return 0;
	if (value > 1) return 1;
	return value;
}

function strongOutOfOrderEmission(state, emissions) {
	const [current, following] = NEXT[state.phase] || NEXT.standing;

	return PHASES.some(
		(phase) =>
			phase !== current &&
			phase !== following &&
			emissions[phase] >= FORWARD_EMISSION,
	);
}

function nextPhase(state, emissions, frame) {
	const [current, following] = NEXT[state.phase] || NEXT.standing;
	const threshold =
		state.phase === "rising" && following === "standing"
			? RETURN_TO_STANDING_EMISSION
			: FORWARD_EMISSION;
	const risingAllowed =
		state.phase !== "pushup" ||
		following !== "rising" ||
		frame.worldBodyVerticalSpan >= RISING_MIN_BODY_VERTICAL_SPAN;

	return emissions[following] >= threshold && risingAllowed ? following : current;
}

function preservePushupCandidate(state) {
	return state.phase === "pushup" ? state : resetCandidate(state);
}

function resetCandidate(state) {
	return { ...state, phase: "standing", phaseStartedAtMs: null };
}

function transition(state, phase, tMs) {
	if (phase === state.phase) {
		return {
			...state,
			phaseStartedAtMs: state.phaseStartedAtMs ?? tMs,
		};
	}

	return { ...state, phase, phaseStartedAtMs: tMs };
}

function outsideRefractory(state, tMs) {
	return state.lastRepAtMs == null || tMs - state.lastRepAtMs >= REFRACTORY_MS;
}

function recordRep(state, tMs) {
	return {
		...state,
		lastRepAtMs: tMs,
		cadenceMs: state.cadenceMs.concat(tMs),
	};
}

function finiteOr(value, fallback) {
	return Number.isFinite(value) ? value : fallback;
}

export { PHASES };
