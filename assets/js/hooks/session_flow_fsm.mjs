export function initialFlowState() {
	return {
		mode: "idle",
		workoutTimeline: [],
		blockCount: 0,
		activeSegment: null,
		warmupResult: { burpeeCountDone: 0, durationSec: 0 },
		workoutResult: null,
		captureMode: "timed",
	};
}

export function flowTransition(state, event) {
	switch (event.type) {
		case "SESSION_READY":
			return {
				state: {
					...state,
					mode: "capture_prompt",
					workoutTimeline: event.workoutTimeline || [],
					blockCount: event.blockCount || 0,
				},
				commands: [{ type: "showCapturePrompt" }],
			};

		case "WARMUP_SKIP":
			return {
				state: {
					...state,
					mode: "workout_ready_prompt",
					activeSegment: null,
				},
				commands: [{ type: "showWorkoutReadyPrompt" }],
			};

		case "WARMUP_READY":
			return {
				state: {
					...state,
					mode: "warmup_countdown",
					activeSegment: "warmup",
				},
				commands: [
					{
						type: "startSegment",
						segment: "warmup",
						timeline: event.warmupTimeline || [],
						blockCount: state.blockCount,
						burpeeCountTarget: event.burpeeCountTarget,
					},
				],
			};

		case "SEGMENT_DONE":
			if (event.segment === "warmup") {
				return {
					state: {
						...state,
						mode: "workout_ready_prompt",
						activeSegment: null,
						warmupResult: event.result || state.warmupResult,
					},
					commands: [{ type: "showWarmupDonePrompt" }],
				};
			}

			if (event.segment === "workout") {
				return {
					state: {
						...state,
						mode: "workout_done",
						activeSegment: null,
						workoutResult: event.result || null,
					},
					commands: [
						{
							type: "pushSessionComplete",
							payload: {
								warmup: {
									burpee_count_done: state.warmupResult.burpeeCountDone,
									duration_sec: state.warmupResult.durationSec,
								},
								main: {
									burpee_count_done: event.result?.burpeeCountDone || 0,
									duration_sec: event.result?.durationSec || 0,
								},
							},
						},
					],
				};
			}
			return { state, commands: [] };

		case "CAPTURE_TIMED":
			return {
				state: { ...state, captureMode: "timed", mode: "warmup_prompt" },
				commands: [{ type: "renderPrompt" }],
			};

		case "CAPTURE_TRACKED":
			return {
				state: { ...state, captureMode: "tracked", mode: "camera_setup" },
				commands: [
					{ type: "chooseTrackedCapture" },
					{ type: "showCameraSetupPrompt" },
				],
			};

		case "CAMERA_SETUP_READY":
			return {
				state: { ...state, mode: "warmup_prompt" },
				commands: [{ type: "renderPrompt" }],
			};

		case "WORKOUT_READY":
			return {
				state: {
					...state,
					mode: "workout_countdown",
					activeSegment: "workout",
				},
				commands: [
					{
						type: "startSegment",
						segment: "workout",
						timeline: state.workoutTimeline,
						blockCount: state.blockCount,
					},
				],
			};

		default:
			return { state, commands: [] };
	}
}
