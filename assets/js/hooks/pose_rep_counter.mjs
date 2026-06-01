import {
	DEFAULT_THRESHOLDS,
	initialFsmState,
	stepFsm,
} from "./pose_rep_fsm.mjs";

const MIN_ADAPTIVE_RANGE = 0.14;

export function initialCounterState() {
	return {
		...initialFsmState(),
		cadenceMs: [],
		signalMin: null,
		signalMax: null,
	};
}

export function countRep(state, sample, thresholds = DEFAULT_THRESHOLDS) {
	const signalMin =
		state.signalMin == null
			? sample.signal
			: Math.min(state.signalMin, sample.signal);
	const signalMax =
		state.signalMax == null
			? sample.signal
			: Math.max(state.signalMax, sample.signal);
	const adaptiveThresholds = thresholdsForRange(
		thresholds,
		signalMin,
		signalMax,
	);
	const { cadenceMs, signalMin: _min, signalMax: _max, ...fsmState } = state;
	const result = stepFsm(fsmState, sample, adaptiveThresholds);
	const nextCadence = result.rep ? [...cadenceMs, sample.tMs] : cadenceMs;

	return {
		state: {
			...result.state,
			cadenceMs: nextCadence,
			signalMin,
			signalMax,
		},
		rep: result.rep,
	};
}

function thresholdsForRange(thresholds, signalMin, signalMax) {
	const range = signalMax - signalMin;

	if (range < MIN_ADAPTIVE_RANGE) {
		return thresholds;
	}

	return {
		...thresholds,
		low: signalMin + range * 0.35,
		high: signalMin + range * 0.65,
	};
}
