import {
	initialTemplateMatcherState,
	recordTemplateSample,
	finishTemplateRecording,
} from "./pose_template_matcher.mjs";

const COUNTDOWN_MS = 3000;
const RECORDING_MS = 5000;

export function initialTemplateCalibration() {
	return {
		phase: "idle",
		startedAtMs: null,
		recordingStartedAtMs: null,
		recording: initialTemplateMatcherState(),
		template: null,
		rejectionReason: null,
	};
}

export function startTemplateCalibration(state, nowMs) {
	return {
		...state,
		phase: "countdown",
		startedAtMs: nowMs,
		recordingStartedAtMs: null,
		recording: initialTemplateMatcherState(),
		template: null,
		rejectionReason: null,
	};
}

export function stepTemplateCalibration(state, sample) {
	if (state.phase === "idle" || state.phase === "ready" || state.phase === "failed") {
		return { state, status: statusFor(state) };
	}

	if (state.phase === "countdown") {
		const elapsedMs = sample.tMs - state.startedAtMs;
		if (elapsedMs < COUNTDOWN_MS) {
			return {
				state,
				status: `Starting in ${Math.ceil((COUNTDOWN_MS - elapsedMs) / 1000)}s`,
			};
		}

		const nextState = {
			...state,
			phase: "recording",
			recordingStartedAtMs: sample.tMs,
			recording: recordTemplateSample(state.recording, sample),
		};
		return { state: nextState, status: "Recording 5s" };
	}

	const recording = recordTemplateSample(state.recording, sample);
	const elapsedMs = sample.tMs - state.recordingStartedAtMs;

	if (elapsedMs < RECORDING_MS) {
		return {
			state: { ...state, recording },
			status: `Recording ${Math.ceil((RECORDING_MS - elapsedMs) / 1000)}s`,
		};
	}

	const result = finishTemplateRecording({ samples: recording.samples });
	if (!result.ok) {
		return {
			state: {
				...state,
				phase: "failed",
				recording,
				rejectionReason: result.reason,
			},
			status: `Rejected: ${result.reason}`,
		};
	}

	return {
		state: {
			...state,
			phase: "ready",
			recording,
			template: result.template,
			rejectionReason: null,
		},
		status: "Template ready",
	};
}

function statusFor(state) {
	if (state.phase === "ready") return "Template ready";
	if (state.phase === "failed") return `Rejected: ${state.rejectionReason}`;
	return "No template";
}
