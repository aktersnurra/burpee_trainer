export function initialFlowState() {
	return {
		mode: "booting",
		captureMode: "no_camera",
		camera: { status: "idle", readiness: "not_ready", reason: null },
		trackingTrust: "disabled",
		trackingReason: null,
		armedStep: null,
		warmup: true,
		workoutTimeline: [],
		warmupResult: { burpeeCountDone: 0, durationSec: 0 },
		workoutResult: null,
		completion: null,
		completionLocked: false,
		saveStatus: "idle",
	};
}

function unchanged(state) {
	return { state, commands: [] };
}

function moved(state, changes, commands = [{ type: "renderFlow" }]) {
	return { state: { ...state, ...changes }, commands };
}

function cameraReady(state) {
	return (
		state.camera.readiness === "ready" || state.camera.readiness === "optimal"
	);
}

function matchingArm(state, event, step) {
	return state.armedStep === step && event.step === step;
}

function plannedBurpees(timeline) {
	return timeline.reduce(
		(total, segment) =>
			total + (segment.kind === "work" ? segment.reps || 0 : 0),
		0,
	);
}

function plannedDurationSec(timeline) {
	return timeline.reduce((total, segment) => {
		if (segment.kind === "work") {
			if (Number.isFinite(segment.duration_sec)) {
				return total + segment.duration_sec;
			}
			return total + (segment.reps || 0) * (segment.sec_per_rep || 0);
		}
		if (segment.kind === "rest") return total + (segment.duration_sec || 0);
		return total;
	}, 0);
}

function completionFor(state, result) {
	const trackingFinished =
		state.captureMode === "camera" && state.trackingTrust === "finished";
	const scheduledRepsDone =
		result.scheduledRepsDone ?? result.burpeeCountDone ?? 0;

	return {
		scheduledRepsDone,
		burpeeCountActual: trackingFinished
			? (result.detectedReps ?? 0)
			: scheduledRepsDone,
		burpeeCountProvenance: trackingFinished ? "camera_confirmed" : "scheduled",
		burpeeCountPlanned: plannedBurpees(state.workoutTimeline),
		durationSecActual: trackingFinished
			? (result.detectedDurationSec ?? 0)
			: result.durationSec || 0,
		durationSecPlanned: plannedDurationSec(state.workoutTimeline),
		detectedReps: result.detectedReps ?? null,
		detectedDurationSec: result.detectedDurationSec ?? null,
		trackingTrust: state.trackingTrust,
		cadenceMs: result.cadenceMs || [],
		mood: 0,
		tags: [],
		contextLowEnergy: false,
		contextHighEnergy: false,
		contextHeatAffected: false,
		primaryLimiter: null,
		preferenceFeedback: null,
		notePost: "",
	};
}

// After ▶, and after the camera sees a raised hand: the warmup when it is on, else the
// workout. Each segment opens on its own countdown.
function beginAfterSetup(state, event, commands = []) {
	if (state.warmup) return startWarmup(state, event, commands);
	return startWorkout(state, commands);
}

function startWarmup(state, event, commands = []) {
	return moved(state, { mode: "warmup_running", armedStep: null }, [
		...commands,
		{
			type: "startSegment",
			segment: "warmup",
			timeline: event.warmupTimeline || [],
			burpeeCountTarget: event.burpeeCountTarget,
		},
	]);
}

function startWorkout(state, commands = []) {
	return moved(
		state,
		{
			mode: "workout_running",
			armedStep: null,
			trackingTrust:
				state.captureMode === "camera" && state.trackingTrust !== "degraded"
					? "observing"
					: state.trackingTrust,
		},
		[
			...commands,
			{
				type: "startSegment",
				segment: "workout",
				timeline: state.workoutTimeline,
			},
		],
	);
}

function finishWorkout(state, result) {
	const workoutResult = result || { burpeeCountDone: 0, durationSec: 0 };
	return moved(
		state,
		{
			mode: "completion_review",
			workoutResult,
			completion: completionFor(state, workoutResult),
			completionLocked: false,
			saveStatus: "idle",
		},
		[{ type: "showCompletion" }],
	);
}

export function flowTransition(state, event) {
	switch (event.type) {
		case "SESSION_READY":
			if (state.mode !== "booting") return unchanged(state);
			return moved(state, {
				mode: "starting",
				warmup: event.choices?.warmup !== false,
				captureMode: event.choices?.camera === true ? "camera" : "no_camera",
				workoutTimeline: event.workoutTimeline || [],
			});

		case "START":
			if (state.mode !== "starting") return unchanged(state);
			if (state.captureMode === "camera") {
				return moved(
					state,
					{
						mode: "camera_starting",
						camera: {
							status: "starting",
							readiness: "not_ready",
							reason: null,
						},
						trackingTrust: "arming",
						trackingReason: null,
					},
					[{ type: "startCamera" }, { type: "renderFlow" }],
				);
			}
			return beginAfterSetup(state, event);

		case "RETRY_CAMERA":
			if (state.mode !== "camera_error") return unchanged(state);
			return moved(
				state,
				{
					mode: "camera_starting",
					camera: {
						status: "starting",
						readiness: "not_ready",
						reason: null,
					},
					trackingTrust: "arming",
					trackingReason: null,
				},
				[
					{ type: "stopCamera" },
					{ type: "startCamera" },
					{ type: "renderFlow" },
				],
			);

		case "CAMERA_STARTED":
			if (state.mode !== "camera_starting") return unchanged(state);
			return moved(
				state,
				{
					mode: "camera_setup",
					camera: {
						status: "arming",
						readiness: "not_ready",
						reason: null,
					},
					armedStep: "camera_setup",
				},
				[{ type: "armGesture", step: "camera_setup" }, { type: "renderFlow" }],
			);

		case "CAMERA_START_FAILED":
			if (state.mode !== "camera_starting") return unchanged(state);
			return moved(state, {
				mode: "camera_error",
				camera: {
					status: "failed",
					readiness: "not_ready",
					reason: event.reason || null,
					stage: event.stage || null,
				},
				trackingTrust: "degraded",
				trackingReason: event.reason || null,
			});

		case "CONTINUE_WITHOUT_CAMERA": {
			if (
				!["camera_starting", "camera_error", "camera_setup"].includes(
					state.mode,
				) ||
				state.captureMode !== "camera"
			) {
				return unchanged(state);
			}

			const commands = [];
			if (state.armedStep) commands.push({ type: "disarmGesture" });
			commands.push({ type: "stopCamera" });

			return beginAfterSetup(
				{
					...state,
					captureMode: "no_camera",
					camera: {
						status: "idle",
						readiness: "not_ready",
						reason: null,
					},
					trackingTrust: "disabled",
					trackingReason: null,
					armedStep: null,
				},
				event,
				commands,
			);
		}

		case "CAMERA_READINESS":
			if (state.captureMode !== "camera" || state.mode !== "camera_setup") {
				return unchanged(state);
			}
			return moved(state, {
				camera: {
					...state.camera,
					status:
						event.readiness === "ready" || event.readiness === "optimal"
							? "ready"
							: "arming",
					readiness: event.readiness,
				},
			});

		case "GESTURE_CONFIRM":
			if (
				state.mode !== "camera_setup" ||
				!matchingArm(state, event, "camera_setup") ||
				!cameraReady(state)
			) {
				return unchanged(state);
			}
			return beginAfterSetup({ ...state, armedStep: null }, event, [
				{ type: "disarmGesture" },
			]);

		case "SEGMENT_DONE":
			if (event.segment === "warmup" && state.mode === "warmup_running") {
				return startWorkout({
					...state,
					warmupResult: event.result || state.warmupResult,
				});
			}
			if (event.segment === "workout" && state.mode === "workout_running") {
				return finishWorkout(state, event.result);
			}
			return unchanged(state);

		case "TRACKING_DEGRADED":
			if (state.captureMode !== "camera") return unchanged(state);
			return moved(state, {
				trackingTrust: "degraded",
				trackingReason: event.reason || null,
			});

		case "TRACKING_FINISHED":
			if (
				state.mode !== "workout_running" ||
				state.captureMode !== "camera" ||
				state.trackingTrust === "degraded"
			) {
				return unchanged(state);
			}
			return moved(state, {
				trackingTrust: "finished",
				trackingReason: null,
			});

		case "SEGMENT_FINISHED":
			if (state.mode !== "workout_running" || state.captureMode !== "camera") {
				return unchanged(state);
			}
			return finishWorkout(
				{ ...state, trackingTrust: "finished", trackingReason: null },
				event.result,
			);

		case "SESSION_DONE":
			if (state.mode !== "workout_running") return unchanged(state);
			return finishWorkout(state, event.result);

		case "FINISH_EARLY":
			if (state.mode !== "workout_running") return unchanged(state);
			return finishWorkout(state, event.result);

		case "RESTORE_COMPLETION_DRAFT":
			if (state.mode !== "starting" || !event.completion) {
				return unchanged(state);
			}
			return moved(
				state,
				{
					mode: "completion_review",
					captureMode: event.captureMode || "no_camera",
					trackingTrust: event.completion.trackingTrust || "disabled",
					trackingReason: event.trackingReason || null,
					workoutResult: {
						burpeeCountDone: event.completion.burpeeCountActual || 0,
						durationSec: event.completion.durationSecActual || 0,
					},
					completion: event.completion,
					completionLocked: false,
					saveStatus: "idle",
				},
				[{ type: "showCompletion", restored: true }],
			);

		case "SERVER_COMPLETION_ACKNOWLEDGED":
			if (
				state.mode !== "completion_review" ||
				state.completionLocked ||
				!event.completion
			) {
				return unchanged(state);
			}
			return moved(state, {
				completion: event.completion,
				completionLocked: true,
			});

		case "COMPLETION_EDITED": {
			if (state.mode !== "completion_review" || state.completionLocked) {
				return unchanged(state);
			}
			const changes = event.changes || {};
			const completion = { ...state.completion };

			for (const field of [
				"burpeeCountActual",
				"durationSecActual",
				"mood",
				"contextLowEnergy",
				"contextHighEnergy",
				"contextHeatAffected",
				"primaryLimiter",
				"preferenceFeedback",
				"notePost",
			]) {
				if (Object.hasOwn(changes, field)) completion[field] = changes[field];
			}
			if (Object.hasOwn(changes, "burpeeCountActual")) {
				completion.burpeeCountProvenance = "manual";
			}
			if (Object.hasOwn(changes, "tags")) {
				completion.tags = [...changes.tags];
			}

			return moved(state, { completion, saveStatus: "idle" });
		}

		case "SAVE_STARTED":
			if (state.mode !== "completion_review") return unchanged(state);
			return moved(state, { saveStatus: "saving" });

		case "SAVE_FAILED":
			if (state.mode !== "completion_review") return unchanged(state);
			return moved(state, { saveStatus: "failed" });

		case "SAVE_SUCCEEDED":
			if (state.mode !== "completion_review") return unchanged(state);
			return moved(state, { mode: "persisted", saveStatus: "saved" });

		default:
			return unchanged(state);
	}
}
