export const DEFAULT_THRESHOLDS = Object.freeze({
	high: 0.72,
	low: 0.35,
	minConfidence: 0.5,
	refractoryMs: 1200,
	recoveryRatio: 0.45,
});

export function initialFsmState() {
	return { phase: "up", sawDown: false, lastRepTMs: null, downSignal: null };
}

export function stepFsm(state, sample, thresholds = DEFAULT_THRESHOLDS) {
	if (sample.confidence < thresholds.minConfidence) {
		return { state, rep: false };
	}

	if (state.phase === "up" && sample.signal <= thresholds.low) {
		return {
			state: {
				...state,
				phase: "down",
				sawDown: true,
				downSignal: sample.signal,
			},
			rep: false,
		};
	}

	if (
		state.phase === "down" &&
		state.downSignal != null &&
		sample.signal < state.downSignal
	) {
		return { state: { ...state, downSignal: sample.signal }, rep: false };
	}

	const recoveryHigh =
		state.downSignal == null
			? thresholds.high
			: state.downSignal +
				(thresholds.high - thresholds.low) * thresholds.recoveryRatio;

	if (state.phase === "down" && sample.signal >= recoveryHigh) {
		const last = state.lastRepTMs;
		const outsideRefractory =
			last == null || sample.tMs - last >= thresholds.refractoryMs;
		const rep = state.sawDown && outsideRefractory;

		return {
			state: {
				phase: "up",
				sawDown: false,
				lastRepTMs: rep ? sample.tMs : state.lastRepTMs,
				downSignal: null,
			},
			rep,
		};
	}

	return { state, rep: false };
}
