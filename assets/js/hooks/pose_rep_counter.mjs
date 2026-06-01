const DEFAULT_OPTIONS = Object.freeze({
	minConfidence: 0.35,
	refractoryMs: 1200,
	bufferMs: 3500,
	minClosenessRange: 0.22,
	downRise: 0.2,
	upRecovery: 0.18,
});

export function initialCounterState() {
	return {
		phase: "standing",
		cadenceMs: [],
		buffer: [],
		baselineCloseness: null,
		peakCloseness: null,
		lastDownTMs: null,
		lastRepTMs: null,
	};
}

export function countRep(state, sample, options = DEFAULT_OPTIONS) {
	if (sample.confidence < options.minConfidence || !Number.isFinite(sample.closeness)) {
		return { state, rep: false };
	}

	const buffer = appendSample(state.buffer, sample, options.bufferMs);
	const baselineCloseness =
		state.baselineCloseness == null
			? sample.closeness
			: Math.min(state.baselineCloseness, sample.closeness);
	const peakCloseness =
		state.peakCloseness == null
			? sample.closeness
			: Math.max(state.peakCloseness, sample.closeness);
	const range = peakCloseness - baselineCloseness;
	const phaseState = { ...state, buffer, baselineCloseness, peakCloseness };

	if (range < options.minClosenessRange) {
		return { state: phaseState, rep: false };
	}

	if (state.phase === "standing") {
		if (sample.closeness >= baselineCloseness + options.downRise) {
			return {
				state: { ...phaseState, phase: "descending" },
				rep: false,
			};
		}

		return { state: phaseState, rep: false };
	}

	if (state.phase === "descending") {
		const downSample = strongestDownSample(buffer);
		if (sample.closeness <= downSample.closeness - options.upRecovery) {
			return {
				state: {
					...phaseState,
					phase: "ascending",
					lastDownTMs: downSample.tMs,
				},
				rep: false,
			};
		}

		return { state: phaseState, rep: false };
	}

	if (state.phase === "ascending") {
		const recovered = sample.closeness <= baselineCloseness + options.upRecovery;
		if (!recovered) return { state: phaseState, rep: false };

		const last = state.lastRepTMs;
		const outsideRefractory = last == null || sample.tMs - last >= options.refractoryMs;
		const rep = outsideRefractory;
		const cadenceMs = rep ? [...state.cadenceMs, sample.tMs] : state.cadenceMs;

		return {
			state: {
				...phaseState,
				phase: "standing",
				cadenceMs,
				lastRepTMs: rep ? sample.tMs : state.lastRepTMs,
			},
			rep,
		};
	}

	return { state: phaseState, rep: false };
}

function appendSample(buffer, sample, bufferMs) {
	const minTMs = sample.tMs - bufferMs;
	return [...buffer, sample].filter((item) => item.tMs >= minTMs);
}

function strongestDownSample(buffer) {
	return buffer.reduce((best, sample) =>
		sample.closeness > best.closeness ? sample : best,
	);
}
