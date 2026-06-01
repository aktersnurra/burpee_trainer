const COUNTDOWN_MS = 3000;
const RECORDING_MS = 10000;

export function initialTraceRecorder() {
	return {
		phase: "idle",
		startedAtMs: null,
		recordingStartedAtMs: null,
		samples: [],
		export: null,
	};
}

export function startTraceRecording(state, nowMs) {
	return {
		...state,
		phase: "countdown",
		startedAtMs: nowMs,
		recordingStartedAtMs: null,
		samples: [],
		export: null,
	};
}

export function stepTraceRecorder(state, sample) {
	if (state.phase === "idle" || state.phase === "complete") {
		return { state, status: statusFor(state) };
	}

	if (state.phase === "countdown") {
		const elapsedMs = sample.tMs - state.startedAtMs;
		if (elapsedMs < COUNTDOWN_MS) {
			return {
				state,
				status: `Trace starts in ${Math.ceil((COUNTDOWN_MS - elapsedMs) / 1000)}s`,
			};
		}

		const samples = [sample];
		return {
			state: {
				...state,
				phase: "recording",
				recordingStartedAtMs: sample.tMs,
				samples,
			},
			status: "Recording trace 10s",
		};
	}

	const samples = [...state.samples, sample];
	const elapsedMs = sample.tMs - state.recordingStartedAtMs;

	if (elapsedMs < RECORDING_MS) {
		return {
			state: { ...state, samples },
			status: `Recording trace ${Math.ceil((RECORDING_MS - elapsedMs) / 1000)}s`,
		};
	}

	return {
		state: {
			...state,
			phase: "complete",
			samples,
			export: {
				version: 1,
				durationMs: elapsedMs,
				samples,
			},
		},
		status: "Trace ready",
	};
}

function statusFor(state) {
	return state.phase === "complete" ? "Trace ready" : "Trace idle";
}
