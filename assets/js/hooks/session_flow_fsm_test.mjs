import assert from "node:assert/strict";
import test from "node:test";

import {
	countOrigin,
	flowTransition,
	initialFlowState,
} from "./session_flow_fsm.mjs";

const step = (state, event) => flowTransition(state, event);

const warmup = {
	warmupTimeline: [{ kind: "work", reps: 3, sec_per_rep: 4 }],
	burpeeCountTarget: 3,
};
const workoutTimeline = [{ kind: "work", reps: 10, sec_per_rep: 5 }];

function readyState(choices) {
	return step(initialFlowState(), {
		type: "SESSION_READY",
		workoutTimeline,
		choices,
	}).state;
}

function cameraSetupState(choices = { camera: true, warmup: true }) {
	let state = readyState(choices);
	state = step(state, { type: "START", ...warmup }).state;
	return step(state, { type: "CAMERA_STARTED" }).state;
}

function readyCameraState(choices) {
	return step(cameraSetupState(choices), {
		type: "CAMERA_READINESS",
		readiness: "ready",
	}).state;
}

function cameraRunningState() {
	return {
		...initialFlowState(),
		mode: "workout_running",
		captureMode: "camera",
		trackingTrust: "observing",
	};
}

function segments(commands) {
	return commands
		.filter((command) => command.type === "startSegment")
		.map((command) => command.segment);
}

test("the session waits for its draft check before it starts", () => {
	const state = readyState({ camera: false, warmup: true });
	assert.equal(state.mode, "starting");
	assert.equal(state.captureMode, "no_camera");

	assert.deepEqual(step(initialFlowState(), { type: "START", ...warmup }).commands, []);
	const started = step(state, { type: "START", ...warmup }).state;
	assert.deepEqual(step(started, { type: "START", ...warmup }).commands, []);
});

test("without the camera, start goes straight into the countdown", () => {
	const withWarmup = step(readyState({ camera: false, warmup: true }), {
		type: "START",
		...warmup,
	});
	assert.equal(withWarmup.state.mode, "warmup_running");
	assert.deepEqual(withWarmup.commands, [
		{
			type: "startSegment",
			segment: "warmup",
			timeline: warmup.warmupTimeline,
			burpeeCountTarget: 3,
		},
	]);

	const withoutWarmup = step(readyState({ camera: false, warmup: false }), {
		type: "START",
		...warmup,
	});
	assert.equal(withoutWarmup.state.mode, "workout_running");
	assert.equal(withoutWarmup.state.trackingTrust, "disabled");
	assert.deepEqual(segments(withoutWarmup.commands), ["workout"]);
});

test("the warmup runs straight into the workout", () => {
	for (const state of [
		step(readyState({ camera: false, warmup: true }), { type: "START", ...warmup })
			.state,
		step(readyCameraState({ camera: true, warmup: true }), {
			type: "GESTURE_CONFIRM",
			step: "camera_setup",
			...warmup,
		}).state,
	]) {
		assert.equal(state.mode, "warmup_running");
		const done = step(state, {
			type: "SEGMENT_DONE",
			segment: "warmup",
			result: { burpeeCountDone: 3, durationSec: 12 },
		});
		assert.equal(done.state.mode, "workout_running");
		assert.deepEqual(done.state.warmupResult, { burpeeCountDone: 3, durationSec: 12 });
		assert.deepEqual(segments(done.commands), ["workout"]);
	}
});

test("with the camera, start opens the camera and failure has explicit recovery", () => {
	let result = step(readyState({ camera: true, warmup: false }), {
		type: "START",
		...warmup,
	});
	assert.equal(result.state.mode, "camera_starting");
	assert.equal(result.state.captureMode, "camera");
	assert.deepEqual(result.commands, [
		{ type: "startCamera" },
		{ type: "renderFlow" },
	]);

	result = step(result.state, {
		type: "CAMERA_START_FAILED",
		reason: "permission_denied",
		stage: "camera_stream",
	});
	assert.equal(result.state.mode, "camera_error");
	assert.equal(result.state.camera.reason, "permission_denied");
	assert.equal(result.state.camera.stage, "camera_stream");

	result = step(result.state, { type: "RETRY_CAMERA" });
	assert.equal(result.state.mode, "camera_starting");
});

test("a raised hand starts only once the camera sees you", () => {
	const ignored = step(cameraSetupState(), {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
		...warmup,
	});
	assert.equal(ignored.state.mode, "camera_setup");
	assert.deepEqual(ignored.commands, []);

	const withWarmup = step(readyCameraState({ camera: true, warmup: true }), {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
		...warmup,
	});
	assert.equal(withWarmup.state.mode, "warmup_running");
	assert.equal(withWarmup.commands[0].type, "disarmGesture");
	assert.deepEqual(segments(withWarmup.commands), ["warmup"]);

	const withoutWarmup = step(readyCameraState({ camera: true, warmup: false }), {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
		...warmup,
	});
	assert.equal(withoutWarmup.state.mode, "workout_running");
	assert.equal(withoutWarmup.state.trackingTrust, "observing");
});

test("continuing without the camera keeps the warmup choice", () => {
	const starting = step(readyState({ camera: true, warmup: true }), {
		type: "START",
		...warmup,
	}).state;
	const failed = step(starting, { type: "CAMERA_START_FAILED", reason: "x" }).state;

	for (const [state, warmupOn] of [
		[starting, true],
		[failed, true],
		[cameraSetupState({ camera: true, warmup: true }), true],
		[readyCameraState({ camera: true, warmup: false }), false],
	]) {
		const result = step(state, { type: "CONTINUE_WITHOUT_CAMERA", ...warmup });
		assert.equal(result.state.captureMode, "no_camera");
		assert.equal(result.state.trackingTrust, "disabled");
		assert.equal(result.state.mode, warmupOn ? "warmup_running" : "workout_running");
		assert.ok(result.commands.some((command) => command.type === "stopCamera"));
		assert.deepEqual(segments(result.commands), [warmupOn ? "warmup" : "workout"]);
	}

	assert.deepEqual(
		step(readyState({ camera: true, warmup: true }), {
			type: "CONTINUE_WITHOUT_CAMERA",
			...warmup,
		}).commands,
		[],
	);
});

test("camera completion pre-fills detected count after absent frames", () => {
	const result = step(cameraRunningState(), {
		type: "SEGMENT_FINISHED",
		result: {
			burpeeCountDone: 99,
			scheduledRepsDone: 5,
			detectedReps: 4,
			detectedDurationSec: 42,
			cadenceMs: [8_000, 18_000, 29_000, 42_000],
		},
	});

	assert.equal(result.state.completion.scheduledRepsDone, 5);
	assert.equal(result.state.completion.burpeeCountActual, 4);
	assert.equal(
		result.state.completion.burpeeCountProvenance,
		"camera_confirmed",
	);
	assert.equal(result.state.completion.durationSecActual, 42);
	assert.equal(result.state.completion.trackingTrust, "finished");
	assert.deepEqual(
		result.state.completion.cadenceMs,
		[8_000, 18_000, 29_000, 42_000],
	);
});

test("explicit work durations plan 38 seconds while actual counts remain camera-only", () => {
	const explicitTimeline = [
		{
			kind: "work",
			reps: 2,
			sec_per_rep: 10,
			sec_per_burpee: 3,
			duration_sec: 20,
		},
		{ kind: "rest", duration_sec: 5 },
		{
			kind: "work",
			reps: 2,
			sec_per_rep: 10,
			sec_per_burpee: 3,
			duration_sec: 13,
		},
	];
	const legacyTimeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
	];

	const noCamera = step(
		{
			...initialFlowState(),
			mode: "workout_running",
			captureMode: "no_camera",
			workoutTimeline: explicitTimeline,
		},
		{
			type: "SESSION_DONE",
			result: { burpeeCountDone: 4, scheduledRepsDone: 4, durationSec: 38 },
		},
	);
	assert.equal(noCamera.state.completion.durationSecPlanned, 38);
	assert.equal(noCamera.state.completion.scheduledRepsDone, 4);
	assert.equal(noCamera.state.completion.burpeeCountActual, 4);
	assert.equal(noCamera.state.completion.burpeeCountProvenance, "scheduled");

	const camera = step(
		{
			...cameraRunningState(),
			workoutTimeline: explicitTimeline,
		},
		{
			type: "SEGMENT_FINISHED",
			result: {
				burpeeCountDone: 4,
				scheduledRepsDone: 4,
				detectedReps: 0,
				detectedDurationSec: 38,
			},
		},
	);
	assert.equal(camera.state.completion.scheduledRepsDone, 4);
	assert.equal(camera.state.completion.burpeeCountActual, 0);
	assert.equal(
		camera.state.completion.burpeeCountProvenance,
		"camera_confirmed",
	);

	const legacy = step(
		{
			...initialFlowState(),
			mode: "workout_running",
			workoutTimeline: legacyTimeline,
		},
		{ type: "SESSION_DONE", result: { scheduledRepsDone: 4, durationSec: 45 } },
	);
	assert.equal(legacy.state.completion.durationSecPlanned, 45);
});

test("restored completion draft enters review without replaying workout", () => {
	const restored = step(
		readyState({ camera: false, warmup: true }),
		{
			type: "RESTORE_COMPLETION_DRAFT",
			captureMode: "camera",
			completion: {
				burpeeCountActual: 9,
				burpeeCountPlanned: 10,
				durationSecActual: 52,
				durationSecPlanned: 50,
				detectedReps: 9,
				detectedDurationSec: 52,
				trackingTrust: "finished",
				cadenceMs: [5_000, 10_000],
				mood: 1,
				tags: ["great_energy"],
				notePost: "Strong finish",
			},
		},
	);

	assert.equal(restored.state.mode, "completion_review");
	assert.equal(restored.state.captureMode, "camera");
	assert.equal(restored.state.trackingTrust, "finished");
	assert.equal(restored.state.completion.notePost, "Strong finish");
	assert.deepEqual(restored.commands, [
		{ type: "showCompletion", restored: true },
	]);

	assert.deepEqual(step(restored.state, { type: "START", ...warmup }).commands, []);
});

test("acknowledged server completion freezes the exact submitted facts", () => {
	const completion = {
		burpeeCountActual: 10,
		burpeeCountPlanned: 10,
		durationSecActual: 55,
		durationSecPlanned: 50,
		mood: 1,
		tags: ["great_energy"],
		notePost: "Acknowledged",
	};
	const review = {
		...initialFlowState(),
		mode: "completion_review",
		completion: { ...completion, notePost: "editable" },
		saveStatus: "saving",
	};

	const acknowledged = step(review, {
		type: "SERVER_COMPLETION_ACKNOWLEDGED",
		completion,
	}).state;
	const forgedEdit = step(acknowledged, {
		type: "COMPLETION_EDITED",
		changes: {
			burpeeCountActual: 999,
			durationSecActual: 999,
			mood: -1,
			tags: ["tired"],
			notePost: "not acknowledged",
		},
	});

	assert.equal(acknowledged.completionLocked, true);
	assert.deepEqual(acknowledged.completion, completion);
	assert.deepEqual(forgedEdit.commands, []);
	assert.equal(forgedEdit.state, acknowledged);
});

test("completion edits only change approved draft fields", () => {
	const completed = step(
		{
			...initialFlowState(),
			mode: "workout_running",
			captureMode: "camera",
			trackingTrust: "observing",
			workoutTimeline: [{ kind: "work", reps: 10, sec_per_rep: 5 }],
		},
		{
			type: "SESSION_DONE",
			result: {
				burpeeCountDone: 9,
				durationSec: 52,
				detectedReps: 8,
				detectedDurationSec: 49,
				cadenceMs: [6100, 6200],
			},
		},
	).state;
	const completedReview = step(completed, {
		type: "REPORT_PENDING_ACKNOWLEDGED",
	}).state;

	const result = step(completedReview, {
		type: "COMPLETION_EDITED",
		changes: {
			burpeeCountActual: 10,
			durationSecActual: 55,
			burpeeCountPlanned: 999,
			durationSecPlanned: 999,
			trackingTrust: "degraded",
			detectedReps: 999,
			detectedDurationSec: 999,
			cadenceMs: [1],
			mood: 1,
			tags: ["great_energy"],
			contextLowEnergy: true,
			contextHighEnergy: false,
			contextHeatAffected: true,
			primaryLimiter: "legs",
			preferenceFeedback: "avoid",
			notePost: "Strong finish",
		},
	});

	assert.deepEqual(result.state.completion, {
		scheduledRepsDone: 9,
		burpeeCountActual: 10,
		burpeeCountProvenance: "manual",
		burpeeCountPlanned: 10,
		durationSecActual: 55,
		durationSecPlanned: 50,
		detectedReps: 8,
		detectedDurationSec: 49,
		trackingTrust: "observing",
		cadenceMs: [6100, 6200],
		mood: 1,
		endedEarly: false,
		tags: ["great_energy"],
		contextLowEnergy: true,
		contextHighEnergy: false,
		contextHeatAffected: true,
		primaryLimiter: "legs",
		preferenceFeedback: "avoid",
		notePost: "Strong finish",
	});
});

test("a remembered camera on a device without one starts as camera off", () => {
	for (const [cameraAvailable, mode] of [
		[false, "warmup_running"],
		[null, "camera_starting"],
		[true, "camera_starting"],
	]) {
		const result = step(readyState({ camera: true, warmup: true }), {
			type: "START",
			cameraAvailable,
			...warmup,
		});
		assert.equal(result.state.mode, mode, String(cameraAvailable));
	}

	const off = step(readyState({ camera: true, warmup: false }), {
		type: "START",
		cameraAvailable: false,
		...warmup,
	});
	assert.equal(off.state.captureMode, "no_camera");
	assert.equal(off.state.trackingTrust, "disabled");
	assert.equal(off.state.mode, "workout_running");
	assert.ok(!off.commands.some((command) => command.type === "startCamera"));
});

test("finishing early from the warmup goes to the finish screen, not the workout", () => {
	const warmingUp = step(readyState({ camera: false, warmup: true }), {
		type: "START",
		...warmup,
	}).state;
	const result = step(warmingUp, {
		type: "FINISH_EARLY",
		result: { burpeeCountDone: 0, scheduledRepsDone: 0, durationSec: 0 },
	});
	assert.equal(result.state.mode, "completion_review");
	assert.equal(result.state.completion.burpeeCountActual, 0);
	assert.deepEqual(segments(result.commands), []);
});

test("the finish screen knows whether the workout ran out or ended early, and has no mood yet", () => {
	const running = step(readyState({ camera: false, warmup: false }), {
		type: "START",
		...warmup,
	}).state;
	const result = { burpeeCountDone: 10, scheduledRepsDone: 10, durationSec: 50 };

	const done = step(running, { type: "SESSION_DONE", result }).state;
	assert.equal(done.completion.endedEarly, false);
	assert.equal(done.completion.mood, null);

	const segmentDone = step(running, { type: "SEGMENT_DONE", segment: "workout", result }).state;
	assert.equal(segmentDone.completion.endedEarly, false);

	const early = step(running, { type: "FINISH_EARLY", result }).state;
	assert.equal(early.completion.endedEarly, true);
	assert.equal(early.completion.mood, null);
});

test("the count's origin is the camera's count when it finished, else the plan's", () => {
	assert.deepEqual(
		countOrigin({ trackingTrust: "finished", detectedReps: 42, scheduledRepsDone: 40 }),
		{ reps: 42, provenance: "camera_confirmed" },
	);
	assert.deepEqual(
		countOrigin({ trackingTrust: "degraded", detectedReps: 12, scheduledRepsDone: 40 }),
		{ reps: 40, provenance: "scheduled" },
	);
	assert.deepEqual(countOrigin({ trackingTrust: "disabled" }), {
		reps: null,
		provenance: "scheduled",
	});
});

test("stepping the count back to its origin gives the origin back its provenance", () => {
	const review = {
		...initialFlowState(),
		mode: "completion_review",
		completion: {
			burpeeCountActual: 42,
			burpeeCountProvenance: "camera_confirmed",
			trackingTrust: "finished",
			detectedReps: 42,
			scheduledRepsDone: 40,
		},
	};
	const corrected = step(review, {
		type: "COMPLETION_EDITED",
		changes: { burpeeCountActual: 43 },
	}).state;
	assert.equal(corrected.completion.burpeeCountProvenance, "manual");

	const back = step(corrected, {
		type: "COMPLETION_EDITED",
		changes: { burpeeCountActual: 42 },
	}).state;
	assert.equal(back.completion.burpeeCountProvenance, "camera_confirmed");
});
