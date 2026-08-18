const PHASES = Object.freeze([
	"upright",
	"lowering_to_floor",
	"floor_work",
	"returning_from_floor",
]);

const NEXT = Object.freeze({
	upright: ["upright", "lowering_to_floor"],
	lowering_to_floor: ["lowering_to_floor", "floor_work"],
	floor_work: ["floor_work", "returning_from_floor"],
	returning_from_floor: ["returning_from_floor", "upright"],
});

const MAX_PHASE_MS = Object.freeze({
	upright: Infinity,
	lowering_to_floor: 6_000,
	floor_work: 15_000,
	returning_from_floor: 6_000,
});

const REFRACTORY_MS = 900;
const MIN_CONFIDENCE = 0.5;
const MIN_MACRO_LANDMARK_CONFIDENCE = 0.5;
const MIN_VISIBLE_FRACTION = 0.35;
const FORWARD_EMISSION = 3;

export function initialBurpeeHsmmState() {
	return {
		phase: "upright",
		phaseStartedAtMs: null,
		lastRepAtMs: null,
		cadenceMs: [],
	};
}

export function stepBurpeeHsmm(state, frame) {
	if (!usable(frame)) return { state, rep: false, repAtMs: null };
	if (expired(state, frame.tMs)) {
		return {
			state: { ...state, phase: "upright", phaseStartedAtMs: frame.tMs },
			rep: false,
			repAtMs: null,
		};
	}

	const phase = nextPhase(state, scoreMacroEmissions(frame));
	const next = transition(state, phase, frame.tMs);
	const rep =
		state.phase === "returning_from_floor" &&
		phase === "upright" &&
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
		finiteOr(frame.poseConfidence, frame.confidence) >= MIN_CONFIDENCE &&
		finiteOr(frame.macroLandmarkConfidence, 0) >=
			MIN_MACRO_LANDMARK_CONFIDENCE &&
		finiteOr(frame.visibleFraction, 0) >= MIN_VISIBLE_FRACTION &&
		[
			frame.wristToAnkle,
			frame.shoulderToAnkle,
			frame.torsoUprightness,
			frame.hipToKnee,
		].every(Number.isFinite)
	);
}

function expired(state, tMs) {
	const maximum = MAX_PHASE_MS[state.phase];
	return (
		state.phaseStartedAtMs != null &&
		Number.isFinite(maximum) &&
		tMs - state.phaseStartedAtMs > maximum
	);
}

function scoreMacroEmissions(frame) {
	const lowering =
		frame.wristToAnkle <= 0.7 &&
		frame.shoulderToAnkle <= 1.35 &&
		frame.torsoUprightness <= 0.7 &&
		frame.dWristToAnkle <= -0.05 &&
		frame.dShoulderToAnkle <= -0.05;
	const floorWork =
		frame.wristToAnkle <= 0.35 &&
		frame.shoulderToAnkle <= 0.65 &&
		frame.torsoUprightness <= 0.3;
	const returning =
		frame.wristToAnkle >= 0.35 &&
		frame.shoulderToAnkle >= 0.55 &&
		frame.torsoUprightness >= 0.3 &&
		frame.torsoUprightness <= 0.7 &&
		frame.hipToKnee <= 0.5 &&
		frame.dWristToAnkle >= 0.05 &&
		frame.dShoulderToAnkle >= 0.05;
	const upright =
		frame.wristToAnkle >= 0.75 &&
		frame.shoulderToAnkle >= 1.4 &&
		frame.torsoUprightness >= 0.75 &&
		frame.hipToKnee >= 0.5;

	return {
		upright: upright ? 4 : 0,
		lowering_to_floor: lowering ? 4 : 0,
		floor_work: floorWork ? 4 : 0,
		returning_from_floor: returning ? 4 : 0,
	};
}

function nextPhase(state, emissions) {
	const [current, following] = NEXT[state.phase] || NEXT.upright;
	return emissions[following] >= FORWARD_EMISSION ? following : current;
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
